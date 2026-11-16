---
type: Reference
title: Odoo Module Selection Matrix
description: Exhaustive Odoo 19 CE core module selection, OCA substitutes for every Enterprise-gated capability, and the in-house ethara_* addon suite.
tags: [odoo, modules, oca, community-edition, hrms, itms, finance]
status: draft
sources:
  - id: odoo-addons
    resource: https://github.com/odoo/odoo/tree/19.0/addons
    title: Odoo 19.0 CE addons tree (verified 2026-09-10)
    last_modified: 2026-09-10T00:00:00Z
  - id: oca-org
    resource: https://github.com/OCA
    title: OCA repositories, 19.0 branches (verified 2026-09-10)
    last_modified: 2026-09-10T00:00:00Z
---

# Ground Rules

Everything below was verified by direct inspection of the `odoo/odoo` 19.0 addons tree and each OCA repo's 19.0 branch on 2026-09-10.[^odoo-addons][^oca-org] Yantra is Community Edition only: modules absent from CE (`hr_payroll`, `hr_appraisal`, `hr_referral`, `planning`, `helpdesk`, `knowledge`, `approvals`, `documents`, `sign`, `account_accountant`, `account_reports`, `account_budget`, `sale_subscription`, `data_cleaning`, `whatsapp`, expense OCR) are Enterprise-gated and are replaced per the substitution table at the end. Notable CE win: the entire India GST stack (`l10n_in`, `l10n_in_edi` e-invoicing/IRN, `l10n_in_ewaybill*`) plus TDS/TCS withholding is Community-licensed core; OCA/l10n-india is empty because core absorbed it. The only India gap is statutory payroll rules, built in-house on the OCA payroll engine.

# Odoo 19 CE Core Modules

## HR (HRMS Core)

| Module | Purpose |
|---|---|
| `hr` | Employee master, departments, jobs, work locations |
| `hr_attendance` | Check-in/out, kiosk mode, overtime engine; natively captures GPS lat/long + IP per check-in (no geofence enforcement — in-house) |
| `hr_holidays` + `hr_holidays_attendance` + `hr_holidays_homeworking` | Leave types, allocations, accruals, approval workflow |
| `hr_contract` | Contracts, `employee_type` selection incl. `contractor`/`freelance`, departure wizard |
| `hr_recruitment` + `hr_recruitment_skills` + `hr_recruitment_survey` + `hr_recruitment_sms` | Full ATS: kanban pipeline, candidates, skills matching, interview forms (survey-backed), SMS |
| `hr_skills` + `hr_skills_slides` + `hr_skills_survey` + `hr_skills_event` | Skills matrix, resume timeline; skills auto-granted by courses, certifications, events — the shared skills graph for marketplace matching |
| `hr_timesheet` + `hr_timesheet_attendance` | Time logging against tasks; attendance-vs-timesheet comparison |
| `hr_work_entry` + `hr_work_entry_holidays` | Work-entry layer consumed by payroll |
| `hr_homeworking` + `hr_homeworking_calendar` | Weekly office/home/other location declaration — hybrid workforce |
| `hr_presence` | Presence detection via IP/session/email signals |
| `hr_org_chart`, `hr_calendar`, `hr_hourly_cost`, `hr_gamification`, `hr_maintenance`, `hr_fleet`, `hr_livechat`, `hr_expense` | Org chart, calendar sync, analytic labor cost, badges, equipment link, fleet link, livechat link, expense claims |

## Website, Recruitment Funnel, eLearning, Community

| Module | Purpose |
|---|---|
| `website` | CMS core — candidate/worker-facing public site |
| `website_hr_recruitment` (+`_livechat`) | Public job board, application funnel, resume digitization |
| `website_slides` + `website_slides_survey` + `website_slides_forum` | eLearning: courses, quizzes, certification exams, course forums — worker training/onboarding academy |
| `survey` | Assessment engine: scored quizzes, certification mode, token invites — shared by recruitment and training |
| `gamification` + `website_profile` | Badges, challenges, karma, public leaderboards — worker reputation layer |
| `website_forum` | Q&A community for the worker network |
| `website_event` + `event` | Virtual/onsite events, registration — career-fair analog |
| `website_blog`, `website_livechat`, `im_livechat`, `website_crm`, `website_project`, `website_payment`, `website_sale` | Content, support chat, lead capture, client project portal, portal payments, storefront (optional) |

## Sales, CRM, Client Billing

| Module | Purpose |
|---|---|
| `crm` (+`crm_livechat`) | B2B client pipeline |
| `sale` + `sale_management` | Quotes/orders, online quote acceptance |
| `sale_project` + `sale_timesheet` | Sell projects/milestones; bill logged hours — the client-side billing engine for delivered work |
| `loyalty` | Promotions/incentive programs |
| `project_hr_skills` | Skill requirements on tasks — internal skill-matching |

## Finance and Payments

| Module | Purpose |
|---|---|
| `account` | GL, invoicing, AR/AP, partial reconciliation, taxes |
| `analytic` | Cost centers: per-project, per-department, per-client P&L |
| `account_debit_note`, `account_edi`, `account_edi_ubl_cii` | Debit notes, e-invoicing framework |
| `l10n_in` + `l10n_in_edi` + `l10n_in_ewaybill` (+`_irn`, `_stock`) | India GST chart, e-invoicing with IRN/QR, e-way bills — all CE |
| `l10n_account_withholding_tax` | TDS/TCS engine (contractor payouts under 194J/194C-class sections) |
| `l10n_in_hr_holidays`, `l10n_in_sale`, `l10n_in_purchase_stock`, `l10n_in_stock` | India-specific behaviors |
| `payment` + providers | `payment_razorpay` (India: UPI/cards/netbanking), `payment_stripe` (global inbound, express checkout), plus `payment_paypal`, `payment_adyen`, `payment_flutterwave`, `payment_payu`, `payment_xendit`, etc. as geography demands |
| `hr_expense` + `project_hr_expense` | Expense claims, project-linked expenses, client re-invoicing |

## Operations, ITMS Base, Productivity

| Module | Purpose |
|---|---|
| `project` + `project_todo` | Task/project engine (internal work; the 200K marketplace uses `services/market`, not this) |
| `maintenance` | Equipment registry, employee assignment, preventive/corrective requests, MTBF/MTTR — ITAM base |
| `repair` | Device repair workflow |
| `purchase` + `purchase_requisition` + `stock` | Procurement and IT-asset stock |
| `fleet` (+`hr_fleet`) | Vehicle fleet |
| `mail`, `calendar`, `contacts`, `resource` | Messaging/chatter bus, scheduling, directory, working calendars |
| `base_automation` | Automation rules + inbound/outbound webhooks — the CE eventing backbone |
| `board`, `digest`, `data_recycle`, `iap`, `utm`, `link_tracker`, `mass_mailing` (+`_sms`, `_slides`), `marketing_card`, `onboarding` | Dashboards, KPI digests, cleanup, campaigns, tracking |

Skipped entirely: `mrp` family, `point_of_sale` family, `lunch`, `stock_landed_costs` (irrelevant to a services/workforce platform).

# OCA Modules (all verified on 19.0 branches)

| Repo | Modules Yantra uses | Replaces / Provides |
|---|---|---|
| OCA/payroll | `payroll`, `payroll_account` | **EE Payroll** — generic engine (structures, rules, payslips); India statutory rules built in-house on top |
| OCA/tier-validation | `base_tier_validation` + `hr_expense_tier_validation`, `account_move_tier_validation`, `account_payment_tier_validation`, `purchase_tier_validation`, `sale_tier_validation`, `partner_tier_validation`, `stock_picking_tier_validation` | **EE Approvals** — multi-level configurable approval chains on any document (note: moved out of OCA/server-ux into its own repo) |
| OCA/helpdesk | `helpdesk_mgmt` + `helpdesk_mgmt_sla`, `website_helpdesk_mgmt`, `helpdesk_mgmt_timesheet`, `helpdesk_mgmt_fieldservice` | **EE Helpdesk** — ticketing, SLA, portal intake for ITMS and worker support |
| OCA/dms | `dms` | **EE Documents** — directory/file DMS with access groups and portal share |
| OCA/sign | `sign_oca` | **EE Sign** — in-Odoo e-signature (templates, roles, portal signing) for contracts/NDAs |
| OCA/knowledge | `document_page` + `document_page_approval`, `document_page_access_group` | **EE Knowledge** — wiki with hierarchy, approval workflow, ACLs for runbooks/SOPs |
| OCA/contract + OCA/agreement | `contract`, `subscription_oca`, `agreement`, `agreement_legal` | **EE Subscriptions** — recurring client billing; contractor/client agreement lifecycle (pairs with `sign_oca`) |
| OCA/mis-builder | `mis_builder`, `mis_builder_budget` | **EE financial reporting/Spreadsheet dashboards** — KPI/financial statement builder |
| OCA/account-budgeting | `account_budget_oca` | **EE Budgets** — budget vs actuals on analytic accounts |
| OCA/account-financial-reporting | `account_financial_report`, `account_tax_balance`, `partner_statement` | **EE account_reports** — dynamic trial balance, GL, P&L/BS, open items |
| OCA/account-financial-tools | `account_asset_management`, `account_fiscal_year`, `account_lock_date_update` | **EE asset management** — fixed assets/depreciation (laptops, perpetual licenses) |
| OCA/account-reconcile | `account_reconcile_oca`, `account_statement_base` | **EE reconciliation UI** — bank statement reconciliation |
| OCA/account-closing | `account_fiscal_year_closing`, `account_invoice_start_end_dates` | Year-end closing, accrual/deferral |
| OCA/bank-payment | `account_payment_order`, `account_banking_mandate` | Payment batch files (SEPA/PAIN-style) for bulk vendor payouts |
| OCA/account-invoicing | `account_invoice_supplier_self_invoice` | Self-billing vendor bills — the gig-payout accounting pattern |
| OCA/account-payment | `account_due_list`, `account_payment_return` | AP due management, payment returns |
| OCA/timesheet | `hr_timesheet_portal`, `hr_timesheet_sheet`, `hr_timesheet_time_control`, `sale_timesheet_invoice_link` | Portal timesheet entry for contractors, weekly submission+approval, start/stop timer |
| OCA/hr + hr-attendance + hr-holidays + hr-expense | `hr_employee_document`, `hr_course`, `hr_employee_calendar_planning`, `hr_attendance_report_theoretical_time`, `hr_attendance_geolocation` (backport if needed), `hr_holidays_public`, `hr_expense_tier_validation` | Employee document vault, courses, theoretical-vs-actual hours, GPS capture, regional public holidays |
| OCA/field-service | `fieldservice` + `fieldservice_skill`, `fieldservice_timesheet`, `fieldservice_subcontracting`, `fieldservice_isp_account` | **EE Field Service** — onsite dispatch; subcontractor→vendor-bill automation is the reference pattern for pay-per-work |
| OCA/maintenance | `maintenance_plan`, `maintenance_equipment_certification`, `maintenance_request_employee`, equipment hierarchy/contract add-ons | ITAM extensions: preventive plans, asset trees, warranty contracts |
| OCA/project + project-reporting | `project_hr`, `project_task_stage_state`, `project_milestone_status`, `project_timeline`, `project_pivot` | Project governance and reporting |
| OCA/server-auth | `auth_oidc`, `auth_jwt`, `auth_api_key`, `auth_session_timeout`, `password_security` | Keycloak SSO for staff; JWT/API-key auth for services |
| OCA/rest-framework | **Not used** | Deliberately excluded: the API gateway owns the public REST/OpenAPI contract, so Odoo's internal surface uses native `@http.route` controllers + JSON-2 API instead — no in-process REST framework, no `base_rest` lineage (deprecated), no extra version-porting risk |
| OCA/queue | `queue_job`, `queue_job_cron_jobrunner` | Async jobs: channels, priorities, retries, dependency graphs; cron-based runner avoids single-replica LISTEN/NOTIFY constraint |
| OCA/connector | `connector`, `component`, `component_event` | Connector framework for external system bridges |
| OCA/storage | `fs_attachment` (+ S3 backend) | Attachments on S3-compatible object storage — mandatory for multi-pod scaling |
| OCA/web | `web_responsive`, `web_notify`, `web_timeline`, `web_m2x_options`, `web_dark_mode` | Mobile-friendly backend UI (near-mandatory on CE) |
| OCA/server-tools | `auditlog`, `base_exception`, `sentry`, `database_cleanup`, `auto_backup`, `scheduler_error_mailer` | Audit trail (compliance), error tracking, hygiene |
| OCA/server-backend | `base_user_role` | Composable permission roles for 20K-user admin sanity |
| OCA/reporting-engine | `report_xlsx`, `report_csv`, `bi_sql_editor`, `kpi` | Excel/CSV exports, SQL-view reports |
| OCA/partner-contact | `partner_identification`, `base_location`, `partner_deduplicate_*` | ID documents on partners, geo data, dedup (**EE data_cleaning** substitute) |
| OCA/purchase-workflow + sale-workflow | `purchase_request`, `sale_automatic_workflow`, `sale_order_type` | Internal requisitions (IT requests), sales automation |
| OCA/crm | `crm_claim`, `crm_lead_to_task` | Claims, lead-to-task conversion |
| OCA/website | `website_require_login`, `portal_invitation_by_website` | Portal gating and invitations |

# Enterprise Gap → Substitution Summary

| EE capability | Yantra answer |
|---|---|
| Payroll (+India statutory) | OCA `payroll` + in-house `ethara_l10n_in_payroll` rules |
| Approvals | OCA `base_tier_validation` family |
| Helpdesk | OCA `helpdesk_mgmt` (+ in-house livechat-to-ticket bridge) |
| Knowledge | OCA `document_page` |
| Documents / Sign | OCA `dms` / `sign_oca` |
| Planning (shifts) | In-house `ethara_shift` (OCA `hr_shift` as starting reference; auto-plan and open-shift claim built custom) |
| Appraisals | OCA appraisal module (18.0 port) or in-house `ethara_appraisal` with 360°/goal linking |
| Referrals | In-house `ethara_referral` (earnings-share model exceeds EE anyway) |
| Full accounting reports / GSTR filing | OCA `account_financial_report` + `mis_builder`; in-house GSTR-1/3B export in `ethara_gst_returns` (EE `l10n_in_reports` is the only first-party filing path — CE requires this build) |
| Budgets | OCA `account_budget_oca` + `mis_builder_budget` |
| Subscriptions | OCA `subscription_oca` |
| Expense OCR | In-house via `services/assess` OCR pipeline or third-party OCR API |
| Data cleaning | OCA `partner_deduplicate_*` + `database_cleanup` |
| WhatsApp | In-house Meta Cloud API bridge (`services/notify`) surfaced through `mail.thread` |
| Studio (no-code) | Not replaced — schema changes go through code |

# In-House `ethara_*` Addon Suite (inside `services/odoo`)

| Addon | Purpose | Key models / composition |
|---|---|---|
| `ethara_workforce` | Contractor lifecycle: onboarding orchestration (e-sign → `hr.employee` `employee_type='freelance'` + `res.partner` vendor + portal user, kept in sync), gated checklist (ID/background → contract → tax form → payment setup) before work eligibility | Wizard + state machine on employee/partner pair; `sign_oca` + `agreement` integration |
| `ethara_attendance_geo` | Geofence enforcement: per-site/per-employee allowed radius, `@api.constrains` on check-in/out coordinates, exception workflow | Extends `hr_attendance` |
| `ethara_l10n_in_payroll` | India statutory salary rules: PF, ESI, PT, TDS, LWF structures on the OCA engine | Salary rules + rule parameters on `payroll` |
| `ethara_gst_returns` | GSTR-1/GSTR-3B data preparation and export (portal-upload format), 2B reconciliation | Reports over `l10n_in` tax data |
| `ethara_itms` | ITIL layer: `itms.problem`, `itms.change.request` (tier-validation approval routing), CMDB dependency graph on `maintenance.equipment`, assignment history audit trail, BYOD/MDM flags | Extends `maintenance` + `helpdesk_mgmt` + `base_tier_validation` |
| `ethara_license` | Software/SaaS seat register: `itms.software.license` (seats total/used, renewal, cost center, owner), renewal reminder crons | FK to OCA `contract` |
| `ethara_shift` | Shift scheduling for onsite ops: roles, templates, open shifts, portal self-claim | `resource` + `hr` |
| `ethara_referral` | Referral links, vouching, earnings-share accrual (% of referee earnings with caps), ID-verification gating | Links to `services/payout` accruals |
| `ethara_portal` | Worker-facing portal routes (`/my/earnings`, `/my/certifications`, `/my/equipment`), `portal.mixin` + `ir.rule` scoping for every worker-visible model | `portal.CustomerPortal` subclasses |
| `ethara_api` | Service-to-Odoo API surface: native `@http.route` controllers for business operations, secured with OCA `auth_jwt` validators (`auth='jwt_<validator>'`); outbox event emitters (`base_automation` + `queue_job` retry wrapper) | Core `http` + OCA server-auth + queue |
| `ethara_session_redis` | Redis session store override (~150-line `ir.http` override; no OCA-mature module exists) | Core override |
| `ethara_tracker_link` | Receives aggregated activity/screenshot metadata from `services/tracker`, attaches to `account.analytic.line`, over-logging caps and anomaly flags | Custom activity-log model |

# Version and License Compliance

**Version compliance.** All core-module claims were verified by direct inspection of the `odoo/odoo` 19.0 branch (current stable, standard support to September 2028) and each OCA repo's 19.0 branch on 2026-09-10. Absence claims (Enterprise gating) were verified the same way: any addon directory returning 404 on the public repo exists only in the proprietary `odoo/enterprise` repo. Known version caveats: the OCA appraisal module is pending a 19.0 port (open decision in [ROADMAP.md](ROADMAP.md)); `hr_attendance_geolocation` may need an in-house 19.0 backport; all `vertical-*` OCA repos are 18.0-only and unused. API-level compliance for in-house addons: target Odoo 19's `hr.version` model for `employee_type` (moved off `hr.contract`), use the JSON-2 external API or native `@http.route` controllers (XML-RPC is deprecated for removal in Odoo 22), and layer no REST framework inside Odoo — `base_rest` is deprecated by its own maintainers and OCA `fastapi` is deliberately excluded because the external API gateway owns the public REST contract.

**Vendored Ethara code (Assessment v2).** `assessments_be_v2` and `api_auth_gateway` (LGPL-3, from `ethara-etp`) are vendored into the Odoo image under `services/odoo/vendor/`, and the exam app `ethara-assessment-fe` (MIT) under `services/assess-app/vendor/`, each at a pinned commit plus numbered patches (`yantra vendor check` proves the copies). LGPL-3 means Yantra's patches to the two addons are published with them, as the paragraph below requires; the owner confirms Ethara agrees to the vendoring.

**License compliance.** Yantra ships zero Enterprise (OEEL-1) code — that is a hard constraint, not a preference: no `odoo/enterprise` addon may ever be vendored, referenced as a dependency, or copied from. Odoo CE core and most core addons are LGPL-3; OCA modules are a per-module mix of LGPL-3 and AGPL-3 (the `license` key in each `__manifest__.py` is authoritative and must be checked when a module is pinned). Consequences: (1) modifications to LGPL-3/AGPL-3 modules must be published under the same license — Yantra maintains such changes as public forks or upstream OCA contributions rather than private patches; (2) AGPL-3 carries network copyleft — because 200K workers interact with the platform over the network, any modified AGPL module's source must be offered to them, and in-house `ethara_*` addons that extend or import AGPL-3 modules (e.g., `helpdesk_mgmt`, `base_tier_validation` families) are conservatively treated as derivative and licensed AGPL-3 themselves; (3) `ethara_*` addons that depend only on LGPL-3 core may carry a permissive license; (4) the MIT license at the repository root covers this knowledge bundle and original non-addon code (services, Flutter app, specs) only — each `services/*` and addon submodule declares its own license, and the microservices (which merely talk to Odoo over APIs, never linking its code) are unencumbered by copyleft. CI enforces a license manifest audit: every pinned OCA module's declared license is recorded, and any AGPL dependency introduced into an addon triggers a license review of that addon.

[^odoo-addons]: Odoo 19.0 CE addons tree (verified 2026-09-10)
[^oca-org]: OCA repositories, 19.0 branches (verified 2026-09-10)
