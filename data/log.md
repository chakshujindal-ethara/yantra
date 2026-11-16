# Bundle Update Log

## 2026-09-10
* **Creation**: [DATAMODEL](../DATAMODEL.md) — implementation-grade ER specification for all service stores and ethara_* Odoo models; [DESIGN](../DESIGN.md) section 5 marked orientation-only.
* **Infrastructure**: Eleven submodule repositories created under EtharaOrion, seeded with specifications, and wired via relative-URL git submodules; `.github/CODEOWNERS` and placeholder `images/hero.svg` added (mascot election pending).
* **Update**: [README](../README.md) rebuilt to the ENGRAM public-showcase register (hero block, abstract, related work, evidence status, threat model, ASCII-only); CNCF Trail Map alignment added to [INFRASTRUCTURE](../INFRASTRUCTURE.md); NATS JetStream + CloudEvents ratified; Envoy Gateway ingress standardized; [deployment/](../deployment/) remapped to CNCF tooling.
* **Creation**: [DESIGN](../DESIGN.md) high-level design — C4 views, ER diagrams, sequence flows, event topology, state machines, deployment view.
* **Restructure**: `service/` renamed `services/`; `deployment/` DevSecOps spec added; specs authored for `app/`, nine services, and deployment.
* **Update**: OCA `fastapi` dropped for native `@http.route` + `auth_jwt` + JSON-2; license/version compliance section added to [MODULES](../MODULES.md).
* **Restructure**: Concept documents restored to repository root as human-readable artifacts; OKF reserved files (`index.md`, `log.md`) relocated to `data/`.
* **Update**: Added version and license compliance section to [MODULES](../MODULES.md) — Odoo 19.0 verification methodology, OEEL-1 exclusion, LGPL-3/AGPL-3 obligations for ethara_* addons.
* **Creation**: Scaffolded `app/` (Flutter specification) and `services/` (nine microservice specifications: gateway, market, quality, assess, payout, notify, tracker, analytics, odoo).
* **Creation**: Added community standards — [CONTRIBUTING](../CONTRIBUTING.md), [SECURITY](../SECURITY.md), [CODE_OF_CONDUCT](../CODE_OF_CONDUCT.md), [CHANGELOG](../CHANGELOG.md) (superseding the retired root `log.md`).
* **Initialization**: Established the Yantra OKF v0.2 knowledge bundle — [README](../README.md), [ARCHITECTURE](../ARCHITECTURE.md), [MODULES](../MODULES.md), [REQUIREMENTS](../REQUIREMENTS.md), [INFRASTRUCTURE](../INFRASTRUCTURE.md), [ROADMAP](../ROADMAP.md).
