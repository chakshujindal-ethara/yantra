# Mockup walkthrough: what to test

Open the screens in a browser. No build step, no network beyond Google Fonts. Each screen is one idea: a title, a two-sentence lead, the mocked app, and two notes.

## Mechanics (5 minutes)

1. Sidebar: every entry opens its screen; the active entry is magenta; the number order matches the story.
2. Keyboard: `→` and `←` move between screens; `Tab` reaches every sidebar entry and the theme button; the focus ring is visible.
3. Deep link: copy the address after clicking a screen (ends in `#review` and so on), open it in a new tab, the same screen opens.
4. Theme: the sidebar button under the stage legend switches light and dark; reload keeps the choice; with no choice the page follows the OS. Check magenta appears only on the active entry, primary buttons and the brand mark; status colours are green, blue, amber, red. In dark mode the magenta carries dark text for contrast.
5. Phone width: narrow the window to about 400 px or open on a phone; the sidebar stacks above the screen; nothing scrolls sideways except the repository tree and wide tables inside their own boxes.
6. Reading: every screen has a title, a two-sentence lead, a persona and a stage or step chip, the mocked app, and two notes underneath. If a chip or a note is unclear on first read, that is a finding.

## Screen by screen

| # | Screen | What to check |
|---|---|---|
| 00 | Thesis and stages | The loop reads in order (find, vet, bench, quote, work, review, pay, measure, catalogue). Four stages with weeks and a gate each. "Decisions still open" matches section 6 of the plan. |
| 01 | One repository, a ring of services | The tree matches section 4.2 of the plan. The ring table says which services are built by week 12 and that assess stays in the Odoo image until Stage 2. The three cards (worker mutation, money, release) are the rules you would enforce in review. |
| 02 | The four numbers | Each tile has a baseline and a bench value. The watch list reads as kill tests, not vanity metrics. Ask: could leadership stop the bench from this page alone? |
| 03 | The bench | Skills show an evidence level (claimed, verified, proven), availability has a date and goes stale after 14 days, past quality is visible. Assigned mode is reachable from here. |
| 04 | Talent intake and screening | The funnel is measured per channel (cost per verified professional, verified-to-first-accepted). The hard-question form sits before any human time. Stage 2 matching is labelled as Stage 2. |
| 05 | Project setup and quote | A project is schema, rubric with a version, quality policy, rate card and price card. The quote formula is visible. A batch below its floor shows a warning and asks for a recorded override, not a hard block. |
| 06 | Worker tasks and runner | Pay per unit is visible before the claim. One live claim with a countdown. The unit shows the rubric version it will be judged against and a "rubric unclear" action. |
| 07 | Review with reason codes | A reason code is required on needs-edits and reject. Client-caused codes are marked billable. The model pre-review is labelled advisory. The reviewer never sees their own work. |
| 08 | My Performance | The worker sees their own numbers first, with the same data the pod lead sees. Weights and targets are per project. No CSV upload anywhere. |
| 09 | Hub: environment with quality gate | Lineage to units and people, a rights field, the three gate checks (determinism, pass-rate band, reward-hack audit) with a hard fail, and an exclusive sale as a single-member entitlement. |
| 10 | Client and vendor console | Intake, SLA and throughput, first-pass acceptance, deliveries with manifests, invoices, and feedback that flows back as review events. Labelled Stage 2. |
| 11 | Pay window, margin, trust | The window closes, holds apply, vendor bills with TDS, two approvals, RazorpayX, reconciliation to the paisa. Holds happen before payout, never clawbacks after. Step-up on payout changes. |
| 12 | Roadmap and gates | The Stage 1 table has six steps (foundations 1-2, identity 3-4, market 5-7, money 8-9, delivery 10, pilot 11-12), each with a gate that carries a number. Stage 0, 2 and 3 are the three cards under it. The note maps the stages to the repository's ROADMAP.md phases. |

## Findings to record

For each screen note: wrong numbers, a missing state (empty, loading, error), a label a new team member would not understand, and anything the plan says that the screen does not show. Figures on every screen are examples, not data.
