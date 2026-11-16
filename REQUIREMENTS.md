---
type: Reference
title: Capability Requirements — Competitor Parity Checklist
description: The union of workforce-platform capabilities across Mercor, Scale AI (Outlier/Remotasks), Multimango (TELUS Digital), and Handshake/Handshake AI, mapped to where each capability lives in Yantra.
tags: [requirements, mercor, scale-ai, multimango, handshake, marketplace]
status: draft
sources:
  - id: mercor-docs
    resource: https://talent.docs.mercor.com
    title: Mercor talent documentation (AI interview, payments, referrals, time tracking)
  - id: scale-docs
    resource: https://scale.com/docs
    title: Scale AI Rapid/Pro documentation (pipelines, auditing, calibration)
  - id: handshake
    resource: https://joinhandshake.com/employers/
    title: Handshake employer platform and Handshake AI program docs
  - id: multimango
    resource: https://forum.telus.com/discussions/my_mobility_account/anyone-else-getting-%E2%80%9C404-error%E2%80%9D-on-multimango-tasks/174588
    title: Multimango (TELUS Digital contributor portal) public signals
---

# Purpose

This checklist is the functional bar: Yantra must meet or exceed every capability below. It is the union of observed features across Mercor (AI recruiting marketplace),[^mercor-docs] Scale AI's contributor platforms Outlier/Remotasks (task marketplace + quality machine),[^scale-docs] Multimango (TELUS Digital's contributor task portal — validates geography-tiered rate cards and the cost of unreliable task delivery),[^multimango] and Handshake incl. Handshake AI (verified-credential talent network + expert fellowships).[^handshake] Each row maps to the owning Yantra component (see [ARCHITECTURE.md](ARCHITECTURE.md) and [MODULES.md](MODULES.md)).

# Sourcing and Recruiting

| Capability | Seen at | Yantra owner |
|---|---|---|
| Resume parsing + external profile enrichment (GitHub, LinkedIn, portfolios) | Mercor | `services/assess` + `hr_recruitment` |
| Semantic/natural-language talent search over profiles, transcripts, assessments | Mercor | `services/assess` search index over Odoo skills graph |
| Auto-matching / instant offers to prequalified candidates | Mercor, Handshake | `services/market` matching + `hr_recruitment_skills` |
| Public job board + application funnel with duplicate detection | All | `website_hr_recruitment` |
| Employer brand pages, virtual career fairs, campaigns, bulk messaging | Handshake | `website`, `website_event`, `mass_mailing` |
| Referral program: unique links, earnings-share (% of referee earnings, capped), vouching, ID-verification gating | Mercor | `ethara_referral` + `services/payout` |
| Institution-verified credentials (not self-reported) | Handshake AI | `services/assess` verification pipeline |
| Client-facing direct search and invite of specific workers | Scale (Expert Match) | `services/market` client console |

# Vetting and Assessment

| Capability | Seen at | Yantra owner |
|---|---|---|
| AI video/voice interview: real-time, transcribed, scored; practice mode; bounded retakes | Mercor | `services/assess` |
| Reusable structured assessments (coding, writing, domain) with weighted scoring | Mercor, Scale, Multimango | `survey` + `services/assess` (code sandbox) |
| Certification exams gating task-category access | Scale, Handshake AI | `website_slides_survey` certifications → `services/market` gates |
| Anti-cheat / anti-LLM detection during assessment and live tasking | Mercor, Scale, Handshake AI | `services/assess` detectors |
| Human audit layer over automated scoring | Mercor, Scale | `services/quality` |

# Onboarding

| Capability | Seen at | Yantra owner |
|---|---|---|
| Gated checklist before work eligibility: ID/background check → contract e-sign → tax form → payment setup | Mercor | `ethara_workforce` (with `sign_oca`, `agreement`) |
| General + project-specific onboarding tracks | Scale, Handshake AI | `website_slides` courses per project |
| Paid training modules with knowledge quiz + reviewed practice task | Handshake AI | `website_slides` + `services/quality` review |
| IT/equipment provisioning for onsite staff; access revocation on exit | (internal parity) | `maintenance` + `ethara_itms` + IAM webhooks |

# Work Management and Tracking

| Capability | Seen at | Yantra owner |
|---|---|---|
| Task dashboard with live refresh and per-task pay disclosed before acceptance | Scale, Multimango | `services/market` + Flutter |
| Hourly AND deliverable-based contract types | Mercor, Scale | `services/market` contract models + `sale_timesheet` billing |
| Desktop/mobile time tracker with periodic screenshots and activity sampling | Mercor (Insightful) | `services/tracker` + `ethara_tracker_link` |
| Weekly hour caps, over-logging prevention, anomaly flags | Mercor | `services/tracker` + `ethara_tracker_link` |
| Geolocated/geofenced attendance for onsite and field staff | (internal parity) | `hr_attendance` + `ethara_attendance_geo` |
| Reliable task delivery at scale (no 404s/dead tasks) | Multimango (negative example) | `services/market` SLOs + load testing |
| Pod-based workforce operations: area managers, 1:1 reviews, PIPs | Scale | `hr` hierarchy + `services/quality` performance data |
| Shift scheduling with open-shift self-claim for onsite ops | (EE Planning parity) | `ethara_shift` |

# Quality Management

| Capability | Seen at | Yantra owner |
|---|---|---|
| Multi-stage pipelines: attempt → review → consensus aggregation | Scale | `services/quality` |
| Reviewer hierarchy with percentile-based promotion/demotion | Scale | `services/quality` |
| Seeded evaluation tasks silently scoring accuracy in live batches | Scale | `services/quality` + `services/market` |
| Calibration batches gating production access (target-score graduation) | Scale | `services/quality` |
| LLM-as-judge / multi-agent auto-review layered with human QA | Scale (Archie) | `services/quality` |
| Worker trust/fit scoring from history, skills, integrity signals | Scale | `services/quality` |
| Dispute/appeals workflow on rejections and payment holds | (Scale's failure mode, designed against) | `services/quality` + `helpdesk_mgmt` |
| Dataset-level composite quality scoring | Scale | `services/quality` + `services/analytics` |

# Payments

| Capability | Seen at | Yantra owner |
|---|---|---|
| Multi-rail global payouts: Stripe Connect, Wise, Razorpay | Mercor, Scale | `services/payout` |
| Weekly cadence, defined pay windows, first-payout hold, instant payout (fee) | Mercor, Scale | `services/payout` |
| Transparent rate disclosure pre-acceptance; geography/domain/credential-tiered rate cards | Scale, Multimango, Handshake AI | `services/market` rate cards |
| Real-time earnings dashboard and payout forecasting | Mercor | `services/payout` + Flutter |
| Canonical completion signals → pricing → ledger → client invoice (single source of truth) | Mercor | `services/market` events → Odoo `account` (self-billed vendor bills + `sale_timesheet` client invoicing) |
| Statutory withholding on contractor payouts (TDS) and India GST compliance | (regulatory) | `l10n_account_withholding_tax`, `l10n_in_edi`, `ethara_gst_returns` |
| Payroll for onsite employees (PF/ESI/PT/TDS/LWF) | (regulatory) | OCA `payroll` + `ethara_l10n_in_payroll` |

# Engagement and Community

| Capability | Seen at | Yantra owner |
|---|---|---|
| Karma, badges, public leaderboards, reputation profile | Handshake, (Odoo native) | `gamification`, `website_profile` |
| Upskilling forums and certification communities for high performers | Handshake AI (MOVE) | `website_forum`, `website_slides` |
| Support/escalation channels with SLA | All | `helpdesk_mgmt` + `helpdesk_mgmt_sla` |
| Push notifications, WhatsApp, email, SMS engagement | All | `services/notify`, `mass_mailing`, `mass_mailing_sms` |

# The Closed Loop

The pattern all four competitors converge on — and Yantra's organizing principle — is a closed loop where every stage emits auditable, timestamped signals feeding the next: AI-assisted vetting → gated onboarding → tracked work → multi-layer quality scoring → rate-carded payment → reputation-driven referral and upskilling. In Yantra, those signals are events on the bus, the marketplace's completion records are the canonical source for both worker pay and client billing, and Odoo's ledger is where every rupee/dollar reconciles.

[^mercor-docs]: Mercor talent documentation
[^scale-docs]: Scale AI Rapid/Pro documentation
[^handshake]: Handshake employer platform and Handshake AI program docs
[^multimango]: Multimango (TELUS Digital contributor portal) public signals
