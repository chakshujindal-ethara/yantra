---
type: Design
title: High-Level Design
description: Microservice HLD for Yantra — C4 context and container views, complete ER diagrams across Odoo and service-owned data stores, service-layer call/sequence diagrams, event topology, state machines, and deployment view.
tags: [design, hld, er-diagram, sequence-diagram, microservices, c4]
status: draft
sources:
  - id: architecture
    resource: ARCHITECTURE.md
    title: Yantra System Architecture
  - id: modules
    resource: MODULES.md
    title: Odoo Module Selection Matrix
  - id: infrastructure
    resource: INFRASTRUCTURE.md
    title: Infrastructure and Deployment Topology
---

# Purpose

This document turns [ARCHITECTURE.md](ARCHITECTURE.md) into concrete design views: who touches the system (context), what runs (containers/services), how calls flow (sequences), what data lives where (ERDs per store, honoring database-per-service), how state evolves (state machines), and where it all deploys. Diagrams are Mermaid; each view ends with the reasoning behind it.

# 1. System Context (C4 Level 1)

```mermaid
flowchart TB
    subgraph ACTORS[Actors]
        OW["Online Worker (200K)<br/>annotators, experts, gig engineers"]
        OE["Onsite Employee (20K)<br/>staff, managers"]
        CL["Client<br/>enterprise buyer of work"]
        OPS["HR / Finance / IT Ops<br/>platform administrators"]
        CAND["Candidate<br/>public applicant"]
    end

    YANTRA(("Yantra Platform"))

    subgraph EXT[External Systems]
        KC[Keycloak IdP]
        RAILS["Payment Rails<br/>Stripe Connect · Wise · Razorpay"]
        NIC["NIC e-Invoice / GST portal"]
        FCM[Firebase Cloud Messaging]
        LLM["LLM Providers<br/>interviews, LLM-as-judge"]
        SBX["Code Sandbox<br/>assessment execution"]
        SMTP[SMTP Relay]
        S3[(S3 Object Storage)]
    end

    OW -->|Flutter app| YANTRA
    CAND -->|public website funnel| YANTRA
    OE -->|Odoo backend UI + Flutter| YANTRA
    CL -->|client portal + console| YANTRA
    OPS -->|Odoo backend UI| YANTRA

    YANTRA --> KC & RAILS & NIC & FCM & LLM & SBX & SMTP & S3
```

**Reasoning.** Five human roles, two fundamentally different access paths: heavy ORM users (employees, ops) go straight to Odoo's UI; scale users (workers, candidates) only ever see Flutter/web surfaces backed by the gateway. External integrations are all owned by specific services (never by Odoo directly), which section 2 makes explicit.

# 2. Container View — Microservice HLD (C4 Level 2)

```mermaid
flowchart TB
    subgraph EDGE[Edge]
        FL["Flutter App<br/>(app/ submodule)"]
        WEB["Public Website + Portal<br/>(Odoo website_* )"]
    end

    subgraph GW_L[API Layer]
        GW["services/gateway<br/>REST/OpenAPI · Keycloak JWT ·<br/>rate limits · idempotency keys · backpressure"]
    end

    subgraph SVCS["Domain Services (services/*, database-per-service)"]
        MKT["services/market<br/>work units · claims · rate cards"]
        QLT["services/quality<br/>pipelines · reviewer hierarchy ·<br/>calibration · disputes"]
        ASS["services/assess<br/>AI interviews · assessments ·<br/>anti-cheat · KYC"]
        PAY["services/payout<br/>earnings ledger · rails ·<br/>referral accruals"]
        NTF["services/notify<br/>FCM · email · SMS · WhatsApp"]
        TRK["services/tracker<br/>activity ingestion · screenshots ·<br/>anomaly flags"]
        ANL["services/analytics<br/>CDC read models · BI"]
    end

    subgraph ERP["System of Record (services/odoo)"]
        OWEB["odoo-web<br/>HTTP workers"]
        OWS["odoo-websocket<br/>gevent"]
        OCRON["odoo-cron"]
        OJOB["odoo-jobs<br/>queue_job"]
        ADD["Odoo 19 CE + OCA + ethara_* addons<br/>HR · Finance · ITMS · Projects · eLearning"]
    end

    subgraph MSG[Messaging]
        BUS[["Event Bus: NATS JetStream (CloudEvents)"]]
        DBZ["Debezium CDC"]
    end

    subgraph DATA[Data Layer]
        PGO[("Odoo PostgresCluster<br/>Crunchy PGO · Patroni · pgBouncer")]
        SDB[("Service PostgresClusters<br/>one schema/cluster per service")]
        RED[("Redis<br/>sessions · idempotency · cache")]
        OBJ[("S3 Object Storage<br/>filestore · screenshots · documents")]
    end

    FL --> GW
    WEB --> OWEB
    GW --> MKT & QLT & ASS & PAY & NTF & TRK
    GW -->|"native @http.route + auth_jwt<br/>JSON-2 API (low volume)"| OWEB

    MKT & QLT & ASS & PAY & NTF & TRK -->|pub/sub| BUS
    BUS -->|outbox consumer| OJOB
    OWEB & OCRON & OJOB -->|base_automation webhooks| BUS

    ADD --- OWEB & OWS & OCRON & OJOB
    OWEB & OWS & OCRON & OJOB --> PGO
    MKT & QLT & ASS & PAY & NTF & TRK --> SDB
    OWEB --> RED
    GW --> RED
    OWEB --> OBJ
    TRK --> OBJ
    PGO --> DBZ --> ANL
    ANL --> SDB

    PAY --> RAILS2["Stripe/Wise/Razorpay"]
    NTF --> FCM2["FCM/SMTP/WhatsApp"]
    ASS --> LLM2["LLM + Sandbox"]
    OWEB --> NIC2["NIC e-Invoice"]
```

**Reasoning.** The gateway is the single choke point for all 200K-worker traffic — it is where auth, idempotency, and backpressure live, so no downstream component needs to defend itself against retry storms. Services never share databases and never write into Odoo's tables; Odoo's only inbound surfaces are its own UI, thin authenticated controllers, and queue-buffered event consumption. Odoo runs as four deployment roles (see [INFRASTRUCTURE.md](INFRASTRUCTURE.md)) because HTTP, websocket, cron, and async-job workloads scale on different axes.[^infrastructure]

# 3. Service-Layer Call Flows

## 3.1 Task Lifecycle — claim → submit → review → pay (the flagship flow)

```mermaid
sequenceDiagram
    autonumber
    participant F as Flutter
    participant G as gateway
    participant M as market
    participant Q as quality
    participant P as payout
    participant B as Event Bus
    participant J as odoo-jobs
    participant O as Odoo (ledger)

    F->>G: GET /tasks/available (JWT)
    G->>M: list units (worker skill/cert/trust filters)
    M-->>F: units + per-unit pay (rate card)
    F->>G: POST /units/:id/claim (Idempotency-Key)
    G->>G: dedup key check (Redis)
    G->>M: claim(worker, unit)
    M->>M: SELECT ... FOR UPDATE SKIP LOCKED
    M-->>F: claim confirmed (deadline, instructions)
    F->>G: POST /units/:id/submit (payload ref)
    G->>M: submit
    M->>B: publish unit.submitted
    B->>Q: consume unit.submitted
    Q->>Q: pipeline: auto-checks → LLM-judge → reviewer(s)
    alt accepted
        Q->>B: publish review.accepted (canonical completion signal)
        B->>M: mark unit COMPLETED
        B->>P: accrue earning (rate card price)
        B->>J: enqueue ledger sync
        J->>O: analytic line + self-billed vendor bill accrual (TDS-aware)
    else rejected
        Q->>B: publish review.rejected (reasons)
        B->>M: unit REJECTED (rework/reassign policy)
        Q-->>F: feedback + dispute option (via notify)
    end
```

**Reasoning.** The completion signal emitted by quality — not the submission, not the claim — is the single canonical event that drives worker pay, client billing, and trust scoring (the Mercor architecture lesson in [REQUIREMENTS.md](REQUIREMENTS.md)). Odoo sees only serialized, queue-buffered aggregates; a 20K-concurrent claim storm never generates a single Odoo write.

## 3.2 Worker Onboarding — gated checklist

```mermaid
sequenceDiagram
    autonumber
    participant F as Flutter
    participant G as gateway
    participant A as assess
    participant O as Odoo (ethara_workforce)
    participant P as payout
    participant M as market
    participant B as Event Bus

    F->>G: apply (profile, resume)
    G->>O: create hr.candidate (website funnel parity)
    F->>G: take assessment / AI interview
    G->>A: run assessment (sandbox, anti-LLM checks)
    A->>B: publish assessment.passed (scores → skills)
    B->>O: grant hr.skills, advance applicant stage
    O->>O: offer accepted → onboarding checklist opens
    F->>G: KYC + ID verification
    G->>A: verify identity/background
    F->>G: sign contract
    G->>O: sign_oca request → agreement signed
    F->>G: tax form (W-8/W-9/PAN)
    F->>G: payout account setup
    G->>P: create rail account (Stripe/Wise/Razorpay)
    O->>O: checklist complete → create hr.employee(freelance) + res.partner(vendor) + portal user (kept in sync)
    O->>B: publish worker.eligible
    B->>M: activate worker profile (tier, rate card eligibility)
    B->>P: enable payouts
```

**Reasoning.** Odoo owns the compliance-bearing artifacts (signed agreement, tax form, employee/vendor identity) because they are HR/finance records; the services own the high-volume steps (assessment, KYC). Work eligibility is provably gated: `market` only activates on the `worker.eligible` event, which `ethara_workforce` emits only when every checklist item is complete.

## 3.3 Onsite Attendance — offline-first geofenced check-in

```mermaid
sequenceDiagram
    autonumber
    participant F as Flutter (offline queue)
    participant G as gateway
    participant J as odoo-jobs
    participant O as Odoo (ethara_attendance_geo)

    F->>F: check-in tap → local SQLite queue (uuid, ts, lat/long)
    F->>G: sync events (Idempotency-Key = event uuid)
    G->>G: dedup (Redis) — connectivity flaps ≠ double check-in
    G->>J: enqueue attendance.write batch
    J->>O: create hr.attendance (lat/long, IP, mode)
    O->>O: geofence constraint: within site radius?
    alt inside radius
        O-->>F: confirmed (via notify)
    else outside radius
        O->>O: flag + exception workflow (manager approval)
        O-->>F: flagged, pending review
    end
```

## 3.4 Payout Run — weekly cycle with ledger reconciliation

```mermaid
sequenceDiagram
    autonumber
    participant S as scheduler
    participant P as payout
    participant O as Odoo (accounting)
    participant R as Rails (Stripe/Wise/Razorpay)
    participant N as notify

    S->>P: open pay-window close (weekly)
    P->>P: aggregate accepted earnings per worker (holds, caps, referral shares)
    P->>O: draft self-billed vendor bills (per res.partner, TDS computed)
    O-->>P: bill ids + withheld amounts
    P->>R: execute payout batch (net amounts, per rail)
    R-->>P: transfer statuses (webhooks)
    P->>O: reconcile: register payments against bills
    P->>N: earnings statements → workers (push + email)
    Note over P,O: invariant — every paisa in rails equals ledger net of TDS
```

# 4. Event Topology

```mermaid
flowchart LR
    subgraph Producers
        OD[Odoo outbox<br/>base_automation + queue_job]
        MKT2[market]
        QLT2[quality]
        ASS2[assess]
        PAY2[payout]
        TRK2[tracker]
    end

    subgraph TOPICS[Event Bus Topics]
        T1([worker.lifecycle<br/>applied · eligible · suspended · offboarded])
        T2([work.units<br/>published · claimed · submitted · completed · rejected])
        T3([quality.verdicts<br/>accepted · rejected · calibration · trust.updated])
        T4([payments<br/>earning.accrued · payout.executed · payout.failed])
        T5([hr.sync<br/>employee.updated · skills.granted · cert.earned])
        T6([tracking<br/>anomaly.flagged · cap.exceeded])
    end

    subgraph Consumers
        C1[market ← T1 T3]
        C2[quality ← T2 T6]
        C3[payout ← T3 T1]
        C4[notify ← all]
        C5[odoo-jobs ← T2 T3 T4]
        C6[analytics ← all + CDC]
    end

    OD --> T1 & T5
    MKT2 --> T2
    QLT2 --> T3
    ASS2 --> T5
    PAY2 --> T4
    TRK2 --> T6
    T1 & T2 & T3 & T4 & T5 & T6 --> C4 & C6
    T1 & T3 --> C1
    T2 & T6 --> C2
    T3 & T1 --> C3
    T2 & T3 & T4 --> C5
```

**Reasoning.** Topics are domain-aligned, not service-aligned, so consumers subscribe to business facts rather than implementation details. `notify` and `analytics` are universal consumers. Odoo both produces (HR master-data changes) and consumes (ledger-bound facts) — always through the outbox/queue bridge, never with a broker client in-process.

# 5. Data Design — ER Diagrams (orientation)

Database-per-service is a hard rule: each diagram below is a physically separate store. Cross-store references are **ids, not foreign keys** (e.g., every service row carrying `partner_ref` refers to Odoo's `res.partner.id` but is not FK-constrained across databases); consistency is eventual, via events. The diagrams in this section are condensed for orientation; the authoritative, implementation-grade schema — every table, every typed column, keys, checks, indexes, partitioning, retention, and roles — is [DATAMODEL.md](DATAMODEL.md), which supersedes this section for implementation purposes.

## 5.1 Odoo System of Record (condensed to platform-critical entities)

```mermaid
erDiagram
    RES_PARTNER ||--o| RES_USERS : "portal/internal login"
    RES_PARTNER ||--o| HR_EMPLOYEE : "1:1 for workers (ethara_workforce sync)"
    HR_EMPLOYEE ||--o{ HR_VERSION : "contract/version history (employee_type)"
    HR_EMPLOYEE ||--o{ HR_ATTENDANCE : "check-ins (lat/long, IP, mode)"
    HR_EMPLOYEE ||--o{ HR_LEAVE : "time off"
    HR_EMPLOYEE ||--o{ HR_SKILL_LEVEL : "skills graph"
    HR_EMPLOYEE ||--o{ ACCOUNT_ANALYTIC_LINE : "timesheets"
    HR_EMPLOYEE ||--o{ PAYSLIP : "OCA payroll (+ India rules)"
    HR_EMPLOYEE ||--o{ SLIDE_CHANNEL_PARTNER : "course enrollment"
    HR_EMPLOYEE ||--o{ GAMIFICATION_BADGE_USER : "badges/karma"
    HR_APPLICANT }o--|| HR_JOB : "ATS pipeline"
    HR_APPLICANT }o--o{ SURVEY_USER_INPUT : "interview/assessment forms"
    RES_PARTNER ||--o{ ACCOUNT_MOVE : "invoices + self-billed vendor bills"
    ACCOUNT_MOVE ||--o{ ACCOUNT_MOVE_LINE : "journal items (GL)"
    ACCOUNT_MOVE_LINE }o--o| ACCOUNT_ANALYTIC_ACCOUNT : "cost centers"
    PROJECT_PROJECT ||--o{ PROJECT_TASK : "internal delivery work"
    PROJECT_TASK ||--o{ ACCOUNT_ANALYTIC_LINE : "billable hours"
    SALE_ORDER ||--o{ SALE_ORDER_LINE : "client contracts (timesheet/milestone billing)"
    MAINTENANCE_EQUIPMENT }o--|| HR_EMPLOYEE : "IT asset assignment"
    MAINTENANCE_EQUIPMENT ||--o{ ITMS_ASSIGNMENT_HISTORY : "ethara_itms audit trail"
    ITMS_SOFTWARE_LICENSE }o--o{ HR_EMPLOYEE : "seat assignment (ethara_license)"
    ITMS_SOFTWARE_LICENSE }o--|| CONTRACT_CONTRACT : "renewal/cost (OCA contract)"
    HELPDESK_TICKET }o--o| MAINTENANCE_EQUIPMENT : "incident on asset"
    ITMS_CHANGE_REQUEST }o--o{ TIER_REVIEW : "approval chain (base_tier_validation)"
    SIGN_REQUEST }o--|| RES_PARTNER : "e-signature (sign_oca)"
    DMS_FILE }o--|| RES_PARTNER : "documents (OCA dms)"

    RES_PARTNER {
        int id PK
        string name
        bool is_worker_vendor
        string vat "PAN/GSTIN"
    }
    HR_EMPLOYEE {
        int id PK
        int partner_ref FK
        string employee_type "employee|contractor|freelance"
        int department_id
    }
    HR_ATTENDANCE {
        int id PK
        decimal in_latitude
        decimal in_longitude
        string in_mode "kiosk|systray|api"
        bool geofence_ok "ethara_attendance_geo"
    }
    ACCOUNT_MOVE {
        int id PK
        string move_type "out_invoice|in_invoice(self-billed)"
        string l10n_in_irn "e-invoice IRN"
        decimal tds_withheld
    }
    ITMS_SOFTWARE_LICENSE {
        int id PK
        int seats_total
        int seats_used
        date renewal_date
    }
```

## 5.2 Marketplace + Quality + Tracker (service-owned stores)

```mermaid
erDiagram
    WORKER_PROFILE ||--o{ CLAIM : makes
    WORKER_PROFILE ||--o{ TRUST_SCORE : "history"
    WORKER_PROFILE ||--o{ CERT_GATE : "unlocked categories"
    CLIENT_PROJECT ||--o{ WORK_BATCH : funds
    WORK_BATCH ||--o{ WORK_UNIT : "fan-out"
    WORK_UNIT ||--o| CLAIM : "exclusive (SKIP LOCKED)"
    WORK_UNIT ||--o{ SUBMISSION : receives
    WORK_UNIT }o--|| RATE_CARD : priced_by
    RATE_CARD }o--|| RATE_TIER : "geo x domain x credential"
    SUBMISSION ||--o{ REVIEW_TASK : triggers
    REVIEW_TASK }o--|| PIPELINE_STAGE : "attempt|llm_judge|review|consensus|audit"
    REVIEW_TASK }o--o| WORKER_PROFILE : "reviewer (hierarchy rank)"
    SUBMISSION ||--o| VERDICT : yields
    VERDICT ||--o| DISPUTE : "appealable"
    WORK_BATCH ||--o{ EVAL_SEED : "hidden gold units"
    WORKER_PROFILE ||--o{ CALIBRATION_RESULT : "gating scores"
    WORKER_PROFILE ||--o{ ACTIVITY_SESSION : "tracker"
    ACTIVITY_SESSION ||--o{ ACTIVITY_SAMPLE : "app/idle sampling"
    ACTIVITY_SESSION ||--o{ SCREENSHOT_REF : "S3 pointers"
    ACTIVITY_SESSION ||--o| ANOMALY_FLAG : "over-logging/caps"

    WORKER_PROFILE {
        uuid id PK
        int partner_ref "res.partner.id (Odoo)"
        string tier
        decimal trust_score_current
        string status "eligible|active|suspended"
    }
    WORK_UNIT {
        uuid id PK
        uuid batch_id FK
        string status "available..paid (see 6.1)"
        string contract_type "hourly|deliverable"
        decimal unit_pay
        timestamptz claim_deadline
    }
    CLAIM {
        uuid id PK
        uuid unit_id FK
        uuid worker_id FK
        string idempotency_key UK
        timestamptz claimed_at
    }
    VERDICT {
        uuid id PK
        string outcome "accepted|rejected"
        jsonb quality_scores
        bool is_canonical_completion
    }
    RATE_TIER {
        uuid id PK
        string geography
        string domain
        string credential_level
        decimal rate
    }
```

## 5.3 Assessment + Payout + Referral + Notify (service-owned stores)

```mermaid
erDiagram
    CANDIDATE_REF ||--o{ INTERVIEW : takes
    INTERVIEW ||--o{ INTERVIEW_TURN : "transcript + scores"
    CANDIDATE_REF ||--o{ ASSESSMENT_ATTEMPT : attempts
    ASSESSMENT_ATTEMPT ||--o| SANDBOX_RUN : "code execution receipt"
    ASSESSMENT_ATTEMPT ||--o| INTEGRITY_CHECK : "anti-LLM/plagiarism"
    CANDIDATE_REF ||--o| KYC_VERIFICATION : "ID/background"
    WORKER_REF ||--o{ EARNING : accrues
    EARNING }o--|| COMPLETION_EVENT : "from quality verdict (canonical)"
    WORKER_REF ||--o| RAIL_ACCOUNT : "Stripe/Wise/Razorpay"
    PAYOUT_BATCH ||--o{ PAYOUT_TXN : contains
    PAYOUT_TXN }o--|| EARNING : settles
    PAYOUT_TXN }o--|| RAIL_ACCOUNT : via
    PAYOUT_TXN ||--o| LEDGER_LINK : "Odoo vendor bill + payment ids"
    WORKER_REF ||--o{ REFERRAL_EDGE : "referrer -> referee"
    REFERRAL_EDGE ||--o{ REFERRAL_ACCRUAL : "% share, capped"
    WORKER_REF ||--o{ DEVICE_TOKEN : "FCM"
    WORKER_REF ||--o{ NOTIFICATION : receives

    EARNING {
        uuid id PK
        uuid worker_ref FK
        decimal gross
        decimal tds_estimate
        string status "accrued|held|billed|paid"
        uuid completion_event_id FK
    }
    PAYOUT_TXN {
        uuid id PK
        string rail "stripe|wise|razorpay"
        decimal net_amount
        string rail_txn_id
        string status "pending|settled|failed|returned"
    }
    REFERRAL_EDGE {
        uuid id PK
        uuid referrer FK
        uuid referee FK
        decimal share_pct
        decimal cap_amount
        bool id_verified
    }
    LEDGER_LINK {
        uuid id PK
        int odoo_vendor_bill_id "account.move"
        int odoo_payment_id
        bool reconciled
    }
```

**Reasoning.** Three deliberate seams: (1) money truth is split — services compute and execute, but Odoo's GL is where every amount reconciles (`LEDGER_LINK` is the audit bridge); (2) `COMPLETION_EVENT`/`VERDICT.is_canonical_completion` encodes the single-source-of-truth rule in the schema itself; (3) high-churn rows (claims, samples, review tasks) never live in Odoo, keeping the ERP's tables cold enough for 20K-user interactive use.

# 6. State Machines

## 6.1 Work Unit Lifecycle

```mermaid
stateDiagram-v2
    [*] --> DRAFT: batch fan-out
    DRAFT --> AVAILABLE: published (rate card bound)
    AVAILABLE --> CLAIMED: claim (SKIP LOCKED, deadline set)
    CLAIMED --> AVAILABLE: deadline expired / released
    CLAIMED --> SUBMITTED: worker submits
    SUBMITTED --> IN_REVIEW: pipeline start
    IN_REVIEW --> ACCEPTED: verdict accepted (canonical completion)
    IN_REVIEW --> REJECTED: verdict rejected
    REJECTED --> DISPUTED: worker appeals
    DISPUTED --> ACCEPTED: appeal upheld
    DISPUTED --> CLOSED_REJECTED: appeal denied
    REJECTED --> AVAILABLE: rework policy (re-queue)
    ACCEPTED --> PAYABLE: earning accrued
    PAYABLE --> PAID: payout batch settled + ledger reconciled
    PAID --> [*]
    CLOSED_REJECTED --> [*]
```

## 6.2 Worker Lifecycle

```mermaid
stateDiagram-v2
    [*] --> APPLIED: funnel application
    APPLIED --> ASSESSED: interview + assessments passed
    ASSESSED --> OFFERED: match/instant offer
    OFFERED --> ONBOARDING: offer accepted (checklist opens)
    ONBOARDING --> ELIGIBLE: KYC + contract + tax + payout complete (worker.eligible)
    ELIGIBLE --> ACTIVE: first claim
    ACTIVE --> SUSPENDED: integrity/trust breach or PIP
    SUSPENDED --> ACTIVE: reinstated
    ACTIVE --> OFFBOARDED: exit (access revoked, equipment returned, final settlement)
    SUSPENDED --> OFFBOARDED
    OFFBOARDED --> [*]
```

**Reasoning.** Both machines are event-sourced onto the bus (section 4): every transition is an auditable, timestamped fact — the property all four competitor platforms converge on and the substrate for trust scoring, dispute resolution, and statutory audit.

# 7. Deployment View

```mermaid
flowchart TB
    subgraph K8S[Kubernetes Cluster]
        subgraph ING[Ingress]
            NG["Envoy Gateway ingress<br/>TLS, /websocket WS-aware, affinity for OWS only"]
        end
        subgraph NS_EDGE[ns: edge]
            GWD["gateway Deployment (HPA)"]
        end
        subgraph NS_SVC[ns: services]
            SD["market · quality · assess · payout ·<br/>notify · tracker · analytics Deployments (HPA)"]
        end
        subgraph NS_ODOO[ns: odoo]
            OW2["odoo-web ×40–85 pods<br/>(4 workers/pod, HPA)"]
            OWS2["odoo-websocket (no CPU HPA)"]
            OC2["odoo-cron"]
            OJ2["odoo-jobs (queue_job_cron_jobrunner)"]
            UP["module-upgrade Job (-u, blue-green cutover)"]
        end
        subgraph NS_DATA[ns: data]
            PG1[("PostgresCluster odoo<br/>3 replicas · pgBouncer(transaction)")]
            PG2[("PostgresCluster services")]
            RD[("Redis")]
            KA[["NATS JetStream"]]
            DB2["Debezium Connect"]
        end
        subgraph NS_PLAT[ns: platform]
            KC2["Keycloak"]
            MON["Prometheus · Grafana · pgMonitor · Sentry · OTel"]
        end
    end
    OBJ2[("S3 Object Storage")]
    BK[("pgBackRest repos: PVC + S3 (PITR)")]

    NG --> GWD & OW2 & OWS2
    GWD --> SD
    OW2 & OC2 & OJ2 --> PG1
    SD --> PG2 & KA
    OW2 --> RD & OBJ2
    PG1 --> BK
    PG1 --> DB2 --> KA
```

**Reasoning.** Namespaced by blast radius; the Odoo Postgres cluster is isolated from service databases so marketplace load can never starve payroll. Probe design, pooling modes, capacity formulas, and the upgrade-window caveat are specified in [INFRASTRUCTURE.md](INFRASTRUCTURE.md).[^infrastructure]

# 8. Cross-Cutting Design Decisions (trace)

| Decision | Where enforced | Documented |
|---|---|---|
| 200K workers never hit Odoo workers | gateway routing + services owning hot paths | [ARCHITECTURE.md](ARCHITECTURE.md)[^architecture] |
| Canonical completion signal drives pay + billing + trust | `VERDICT.is_canonical_completion`, `payments` topic, ledger sync job | §3.1, §5.3 |
| Idempotency everywhere a mobile client mutates | gateway dedup (Redis) + `CLAIM.idempotency_key` unique constraint | §3.1, §3.3, §5.2 |
| Database-per-service, ids-not-FKs across stores | schema ownership per submodule; CI forbids cross-DB DSNs | §5 |
| No REST framework inside Odoo | native `@http.route` + `auth_jwt` + JSON-2 only | [MODULES.md](MODULES.md)[^modules] |
| No broker client inside Odoo | outbox via `base_automation` + `queue_job` → bridge | §2, §4 |
| CE-only, license-audited dependencies | CI license manifest; AGPL rules for `ethara_*` | [MODULES.md](MODULES.md) |
| Every transition is an auditable event | state machines published to bus; analytics consumes all | §4, §6 |

[^architecture]: Yantra System Architecture
[^modules]: Odoo Module Selection Matrix
[^infrastructure]: Infrastructure and Deployment Topology
