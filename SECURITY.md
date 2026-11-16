---
type: Policy
title: Security Policy
description: Vulnerability reporting policy, scope, and handling commitments for the Yantra platform.
tags: [security, policy, vulnerability-disclosure]
status: stable
---

# Security Policy

Yantra processes highly sensitive data — employee HR records, payroll, statutory tax identifiers, financial ledgers, and payout rails for hundreds of thousands of workers. Security reports are taken seriously and handled with priority.

# Reporting a Vulnerability

**Do not open public issues for security vulnerabilities.** Report privately via email to security@ethara.ai, or through GitHub's private vulnerability reporting on this repository if enabled. Include: a description of the issue and its impact, affected component (repository/submodule, service, addon, or infrastructure layer), reproduction steps or proof of concept, and any suggested remediation. You will receive acknowledgment within 48 hours, a triage assessment within 5 business days, and status updates until resolution. We ask for coordinated disclosure: give us reasonable time to remediate before any public disclosure, and we will credit reporters (unless anonymity is requested) once a fix ships.

# Scope

In scope: this repository and all `services/*` and `app/` submodules; the `ethara_*` Odoo addons; deployment configurations described in [INFRASTRUCTURE.md](INFRASTRUCTURE.md); authentication/authorization flows (Keycloak, portal record rules, JWT validation at the gateway); and data-exposure risks across the worker portal and API surfaces. Out of scope: vulnerabilities in upstream Odoo core or OCA modules (report upstream to Odoo's responsible disclosure program or the OCA maintainers — we will still accept a heads-up and track the pin), social engineering, physical attacks, and denial-of-service findings without a demonstrated amplification defect.

# Supported Versions

During pre-release development, only the `main` branch of each repository is supported. After production release, the latest deployed release and the one preceding it receive security fixes; the Odoo baseline (19.0 CE) receives upstream security patches per Odoo's 3-year support window (to September 2028), and OCA module pins are reviewed on a scheduled cadence.

# Hardening Expectations for Contributors

Contributors must never commit secrets, tokens, or credentials (CI secret scanning enforces this); portal-facing Odoo models require explicit `ir.rule` row-level scoping reviewed in every PR that touches them; all worker-facing endpoints must enforce authentication, rate limiting, and idempotency at the gateway; personal data handling follows least-access principles — HR/payroll data never leaves Odoo's boundary except through audited, purpose-built APIs.
