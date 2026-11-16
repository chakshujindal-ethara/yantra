# ruff: noqa: E501 - prose, kept as one sentence per string so a diff of a policy reads as a diff of text
"""Version 1 of every policy the app shows, moved from the app's constants (`policies_screen.dart`,
`onboarding_screen.dart`) into the database by migration 0005. Frozen: a later text is a new version made with
`PUT /v1/talent/policies/{slug}`, never an edit here."""

from typing import Any

Section = dict[str, Any]


def section(title: str, paragraphs: list[str] | None = None, bullets: list[str] | None = None) -> Section:
    return {"title": title, "paragraphs": paragraphs or [], "bullets": bullets or []}


CONTRACTOR_AGREEMENT = "contractor-agreement"
DPDP_CONSENT = "dpdp-consent"

POLICIES: list[dict[str, Any]] = [
    {
        "slug": CONTRACTOR_AGREEMENT,
        "label": "2026-11",
        "title": "Contractor agreement",
        "summary": "The terms you work under on Yantra.",
        "sections": [
            section(
                "Contractor agreement",
                [
                    "You work as an independent contractor. You are paid per accepted unit at the rate frozen on each "
                    "unit; only an accepted unit creates an earning. You keep the client's material confidential, you do "
                    "not use automated tools where a pool forbids them, and you may stop at any time. Yantra may pause or "
                    "end your access for quality or conduct reasons, with the reason given in writing. Disputes on a "
                    "verdict follow the 14-day dispute process. Either side may end this agreement with notice; earnings "
                    "already accepted are paid out."
                ],
            )
        ],
    },
    {
        "slug": DPDP_CONSENT,
        "label": "2026-11",
        "title": "Consent to use your personal data",
        "summary": "What we keep about you, why, and how to withdraw.",
        "sections": [
            section(
                "Consent",
                [
                    "Under the Digital Personal Data Protection Act, 2023 we ask your consent to store your name, phone, "
                    "city, PAN and bank details to verify who you are, pay you and meet tax rules. Your PAN is kept as a "
                    "keyed hash plus the last four digits; your account number is kept encrypted by the payout system "
                    "and shown only as its last four digits. You may withdraw consent from Profile; payouts then stop. "
                    "You may also ask for your personal data to be erased; it is erased within 30 days, except the "
                    "records a tax or payment law requires us to keep."
                ],
            )
        ],
    },
    {
        "slug": "pay-cycle",
        "label": "1",
        "title": "Pay cycle",
        "summary": "When the week closes, what gets paid and when it lands.",
        "sections": [
            section(
                "The pay week",
                [
                    "A pay week runs from Saturday 00:00 to Friday 23:59, Indian time (IST). Every accepted unit is "
                    "counted in the week its verdict was recorded."
                ],
            ),
            section(
                "From cutoff to your bank",
                [
                    "After the Friday cutoff the week moves through four steps. Nothing is paid before all four are done."
                ],
                [
                    "Review: the accepted units of the week are added up into one statement per worker.",
                    "Two approvals: two people at Yantra check and approve the statement.",
                    "Payout run: the approved amounts are sent in one run, normally early the next week.",
                    "Bank: the money lands in the account ops hold for you, usually within one working day of the run.",
                ],
            ),
            section(
                "Holds",
                bullets=[
                    "Your first payout is held for 7 days after it is approved, once, when you start.",
                    "A hold rolls the amount into the next pay window; it is never lost.",
                ],
            ),
            section(
                "What creates earnings",
                bullets=[
                    "Only an accepted unit creates an earning. A unit that needs edits earns when the resubmission is "
                    "accepted.",
                    "The pay on a unit is frozen when the batch is published; it does not change after you claim.",
                    "Review and audit work pays per completed review at the rate shown on the queue.",
                ],
            ),
            section(
                "Statements and tax",
                bullets=[
                    "You get one statement per pay window, with every accepted unit on it.",
                    "TDS (tax deducted at source) is withheld at your rate and shown as its own line on the statement.",
                    "The statement shows the gross amount, the TDS withheld and the net amount paid.",
                ],
            ),
        ],
    },
    {
        "slug": "disputes",
        "label": "1",
        "title": "Disputes",
        "summary": "How to challenge a verdict you believe is wrong.",
        "sections": [
            section(
                "Raising a dispute",
                bullets=[
                    "One dispute per unit, from My work, within 14 days of the verdict.",
                    "A dispute needs a reason. Say what the rubric asked for and why your answer met it.",
                    "Duplicate requests on the same unit are ignored; the first one stands.",
                ],
            ),
            section(
                "How it is decided",
                [
                    "A person reads the unit, your answer, the rubric version it was judged against and your reason. The "
                    "decision is final."
                ],
            ),
            section(
                "What the outcome changes",
                bullets=[
                    "Upheld: the rejection is cleared from your quality record. Pay never changes, in either direction.",
                    "Dismissed: the verdict stays as it was.",
                ],
            ),
        ],
    },
    {
        "slug": "llm-use",
        "label": "1",
        "title": "Use of AI models",
        "summary": "What you may and may not do with a language model while working.",
        "sections": [
            section("Allowed", bullets=["Spelling and grammar checks.", "Light rephrasing of your own words."]),
            section(
                "Not allowed",
                ["Unless the pool says the opposite, a model must not do the work for you. That means no:"],
                [
                    "having a model write the answer,",
                    "having a model judge model outputs,",
                    "having a model write the rationale,",
                    "having a model predict what code will do.",
                ],
            ),
            section(
                "When use is detected",
                bullets=[
                    "The unit is rejected with the reason code authenticity.",
                    "Repeated use climbs the integrity ladder: removal from the pool, then suspension of the account.",
                ],
            ),
        ],
    },
    {
        "slug": "conduct",
        "label": "1",
        "title": "Conduct",
        "summary": "The rules of the platform and what happens when one is broken.",
        "sections": [
            section(
                "Categories",
                ["Integrity findings fall into six categories."],
                [
                    "Time: claiming units and letting them expire, or working outside the time the claim allows.",
                    "Authenticity: work that is not your own, including undisclosed model use.",
                    "Identity: working under another person's account, or letting someone work under yours.",
                    "Tooling: using tools a pool forbids, or bypassing the task form.",
                    "Network: sharing units, answers or rubrics outside the platform.",
                    "Confidentiality: keeping or passing on client data from a unit.",
                ],
            ),
            section(
                "The ladder",
                ["Each finding takes one rung. The rung depends on how serious and how repeated it is."],
                ["1. The unit is rejected.", "2. Removal from the pool.", "3. The account is suspended."],
            ),
            section(
                "Quality is separate from integrity",
                bullets=[
                    "Low quality never claws back pay that was already accepted.",
                    "Low quality affects your future eligibility for pools, not the money already earned.",
                    "Integrity findings are about honesty, and they are the only thing that moves you up the ladder.",
                ],
            ),
        ],
    },
    {
        "slug": "tracking",
        "label": "1",
        "title": "What we track while you work",
        "summary": "Activity while a claim is live: what is collected, what is not, how long it is kept.",
        "sections": [
            section(
                "What is collected",
                [
                    "While a claim is live and the work screen is open, the app records every 30 seconds whether you were "
                    "active, idle or away from the tab, plus a device id kept in your browser. Hours count against the "
                    "weekly cap of your pool."
                ],
            ),
            section(
                "What is not collected",
                bullets=[
                    "No keystrokes, no window titles, no screen contents in the web app.",
                    "No tracking when no claim is live.",
                ],
            ),
            section(
                "Retention and review",
                bullets=[
                    "Activity samples are kept 30 days, then deleted.",
                    "A flagged pattern is looked at by a person before anything happens to your pay.",
                ],
            ),
        ],
    },
    {
        "slug": "glossary",
        "label": "1",
        "title": "Glossary",
        "summary": "The words used across the app, one line each.",
        "sections": [
            section(
                "Work",
                bullets=[
                    "Unit: the smallest piece of paid work, such as one clip, one caption or one comparison, with its pay "
                    "and rubric version.",
                    "Batch: a set of units imported together under one project, with one frozen pay.",
                    "Pool: a batch you are certified for and can claim from.",
                    "Claim: you taking one unit to work on. One live claim per worker, with a time limit.",
                    "TTL: the time limit on a claim. When it runs out the unit goes back to the pool.",
                    "Manifest: the file shipped with a delivery to the client: checksums, provenance, rubric version, "
                    "counts.",
                ],
            ),
            section(
                "Judging",
                bullets=[
                    "Verdict: the reviewer's decision on a submission: accept, needs edits or reject. Only an accept "
                    "creates money.",
                    "Reason code: a short code required on every rejection, such as timing or glossary.",
                    "Rubric version: the exact version of the judging rules a unit was reviewed against, stored on the "
                    "unit.",
                    "Dispute: your one request, within 14 days, for a person to look at a verdict again.",
                ],
            ),
            section(
                "You",
                bullets=[
                    "Bench: the pool of verified workers with their skills, availability and past quality.",
                    "Certification: a pass on an assessment paper that opens a category of work.",
                ],
            ),
            section(
                "Money",
                bullets=[
                    "Pay window: the weekly period, Saturday to Friday in Indian time, whose accepted earnings are paid "
                    "together.",
                    "Statement: the list of accepted units and the amounts for one pay window.",
                    "Hold: an amount kept back from a payout and rolled into the next window.",
                ],
            ),
        ],
    },
]
