# Yantra, final pack (2 November 2026)

Everything in this folder stands on its own. Read it in this order.

| # | Document | What it is for | Also as HTML |
|---|---|---|---|
| 1 | [Understanding Yantra](01-understanding-yantra.md) | Plain-language guide: what Yantra is, the words, the people, the loop with real numbers, how it is built, the plan, and the questions you will be asked | [html/01-understanding-yantra.html](html/01-understanding-yantra.html) |
| 2 | [System design](02-system-design.md) | The system design: context, containers, repository, deployment, data model, events, sequences, API, security, scale, operations | [html/02-system-design.html](html/02-system-design.html) |
| 3 | [User flows](03-user-flows.md) | One flow per person: worker, reviewer, ops and client, finance, and the Stage 3 factory, each with a diagram and a step table | [html/03-user-flows.html](html/03-user-flows.html) |
| 4 | [Tech stack](04-tech-stack.md) | Every technology, what it does here, why it was chosen, what was not chosen | [html/04-tech-stack.html](html/04-tech-stack.html) |
| 5 | [The unified plan](05-unified-plan.md) | The plan: business, principles, stages and gates, decisions, measures, risks, alternatives | [html/05-unified-plan.html](html/05-unified-plan.html) |
| 6 | [The screens](mockups/unified-plan.html) | Screen mockups for the plan, one screen per journey; [the walkthrough](mockups/WALKTHROUGH.md) says what to test | |
| 7 | [What is new](06-what-is-new.md) | The repository and this pack compared: what was kept, what was added and why, the five proposals, what is deferred | [What-is-new.html](What-is-new.html) |
| 8 | [The enhanced plan](07-enhanced-plan.md) | A second option next to the unified plan: four deployables in Stage 1, sixteen weeks with a hardening week, the path for the current platform, cost, recovery targets, testing, versioning, service levels, a security calendar | [Enhanced-plan.html](Enhanced-plan.html) |
| 9 | [diagrams/](diagrams/) | Every diagram (17) as an editable `.drawio` file (open in diagrams.net or the draw.io desktop app) and as `.svg`; `build_diagrams.py` regenerates both from one model | |

Conventions: the Yantra repository documents (`README.md`, `ARCHITECTURE.md`, `ROADMAP.md`, `MODULES.md`, `DATAMODEL.md`, `INFRASTRUCTURE.md`) are the point of truth. Where this pack proposes a change it says so and marks it as a proposal. Evidence tags: **[D]** disclosed by the company named, **[R]** reported by press or analysts, **[E]** estimate, **[L]** read from Ethara's own repositories.

One-file version of everything above, for sharing: [Yantra.html](Yantra.html). The HTML pages name no files or folders; they point to sections instead.
