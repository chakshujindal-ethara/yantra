---
type: Playbook
title: Contributing Guide
description: How to contribute to Yantra — repository conventions, submodule workflow, documentation standards, and quality gates.
tags: [contributing, workflow, standards]
status: stable
---

# Contributing to Yantra

Thank you for contributing. Yantra is a multi-repository platform: this repository is the knowledge and specification hub, while the Flutter app and each backend microservice live in their own git submodules. Read [ARCHITECTURE.md](ARCHITECTURE.md) before proposing structural changes, and [MODULES.md](MODULES.md) before touching anything Odoo-related.

# Ground Rules

By participating you agree to the [Code of Conduct](CODE_OF_CONDUCT.md). Security issues are never filed as public issues — follow [SECURITY.md](SECURITY.md). All contributions are made under the repository's [MIT license](LICENSE), except contributions to Odoo addon submodules, which follow that submodule's declared license (LGPL-3 or AGPL-3 — see the license compliance section of [MODULES.md](MODULES.md)).

# Repository Structure

Root markdown files are OKF v0.2 concept documents: every document carries YAML frontmatter with at least a `type` key, plus `generated`/`sources` provenance where applicable. The OKF bundle index and update log live in `data/`. Specifications for the Flutter app live in `app/`; per-service specifications live in `services/<name>/`. Code never lives in this repository — it lives in the submodules.

# Documentation Standards

1. **No hard line breaks in prose.** Write each paragraph as a single continuous line and let the renderer soft-wrap. Tables, lists, and code fences are exempt.
2. **Frontmatter is mandatory** on every concept document: `type` (required), `title`, `description`, `tags`, `status` (`draft`/`stable`/`deprecated`), `generated: { by, at }`, and `sources` with stable `id`s for any claim-bearing external material.
3. **Provenance over assertion.** Claims about Odoo/OCA module availability, licensing, or behavior must cite a source (repo tree, manifest, official docs) in `sources`, referenced via markdown footnotes keyed to the source `id`.
4. **Update the trail.** Every meaningful documentation change appends an entry to `data/log.md` and, for released changes, to [CHANGELOG.md](CHANGELOG.md).

# Code Contribution Workflow (submodules)

1. Fork/branch in the relevant submodule repository, not here. Branch names: `feat/<scope>-<summary>`, `fix/<scope>-<summary>`, `docs/<summary>`.
2. Commits follow Conventional Commits (`feat:`, `fix:`, `docs:`, `refactor:`, `test:`, `chore:`) with imperative subjects ≤72 characters.
3. Odoo addons: target Odoo 19.0 CE APIs only — no Enterprise (OEEL-1) imports or dependencies, ever; respect the `ethara_*` namespace; every model change ships with `ir.model.access.csv` entries and record rules; portal-facing models require explicit `ir.rule` scoping and a security review; migrations follow expand/contract discipline.
4. Services: each service owns its bounded context — no service writes directly into another service's database or into Odoo's tables; all cross-service communication goes through published APIs or the event bus; every endpoint accepting mutations must honor idempotency keys.
5. Tests are required for behavior changes; a PR that lowers coverage or deletes failing tests to pass is rejected.
6. Update this hub repository's submodule pointer plus any affected spec document in the same review cycle as the submodule change.

# Pull Request Checklist

Before requesting review: CI green (lint, tests, license audit); documentation updated (spec + changelog/log); no secrets, credentials, or personal data in the diff; for Odoo addons, `__manifest__.py` declares the correct `license` key and the license audit passes; for AGPL-touching changes, confirm the licensing consequences documented in [MODULES.md](MODULES.md).

# Questions

Open a discussion or issue in this repository for architectural questions; use the relevant submodule's tracker for implementation-level issues.
