---
okf_version: "0.2"
---

# Yantra Knowledge Bundle

# Concepts

* [README](../README.md) - Platform overview, core decisions, and repository layout for Yantra, Ethara.AI's unified workforce platform.
* [ARCHITECTURE](../ARCHITECTURE.md) - End-to-end architecture: Odoo 19 CE core, microservices ring, Flutter frontend, Kubernetes/Crunchy PostgreSQL, integration patterns, and scale engineering.
* [DATAMODEL](../DATAMODEL.md) - Implementation-grade data model for every store: typed columns, keys, constraints, indexes, partitioning, retention, roles.
* [MODULES](../MODULES.md) - Exhaustive Odoo 19 CE module selection, OCA substitutes for every Enterprise gap, the in-house ethara_* addon suite, and version/license compliance.
* [REQUIREMENTS](../REQUIREMENTS.md) - Competitor-parity capability checklist (Mercor, Scale AI, Multimango, Handshake) mapped to owning Yantra components.
* [INFRASTRUCTURE](../INFRASTRUCTURE.md) - Kubernetes deployment design: Crunchy Postgres Operator, Odoo deployment roles, pooling, capacity math, and scaling caveats.
* [ROADMAP](../ROADMAP.md) - Phased implementation plan with verification gates, standing workstreams, and open decisions.

# Community

* [CHANGELOG](../CHANGELOG.md) - Chronological history of bundle and specification changes.
* [CONTRIBUTING](../CONTRIBUTING.md) - Contribution workflow, submodule conventions, and authoring standards.
* [CODE_OF_CONDUCT](../CODE_OF_CONDUCT.md) - Community standards (Contributor Covenant v2.1).
* [SECURITY](../SECURITY.md) - Vulnerability reporting policy and scope.

# Specifications

* [app/](../app/) - Flutter application specification (app itself arrives as a git submodule).
* [services/](../services/) - Per-service specifications; each backend microservice arrives as a git submodule.
