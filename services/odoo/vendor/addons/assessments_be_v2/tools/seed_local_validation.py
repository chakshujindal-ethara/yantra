# -*- coding: utf-8 -*-
"""Seed `etp_validate` with the smallest fixture set that exercises every change.

Run with:
    cd src && ../.venv/bin/python odoo-bin shell -c ../src/odoo.conf \
        -d etp_validate --db_port=5433 --log-level=warn < ../seed_validate.py

IDEMPOTENT: every record is looked up by a `VAL-` prefixed name first, so a
second run adjusts rather than duplicates. That matters because a validation pass
usually needs two or three attempts.

WHAT IT BUILDS, and which change each part is for:

  3 logins       cj.admin / cj.manager / cj.candidate - the role ladder
  1 generator    with 6 keyed questions - the shortlisting pool
  1 DRAFT asmt   shortlist editable, ticks live
  1 LAUNCHED     shortlist inert, "the paper is fixed" notice
  1 portal user  at a candidate's address - the refusal path

One password for all of them so the validation guide has one thing to remember.
Override it with SEED_PASSWORD if a local password-policy addon refuses the
default. This carries no real credential - it only ever reaches a throwaway local
database - but a hard-coded literal in a tracked file is a habit worth not
forming.
"""
import os

PASSWORD = os.environ.get("SEED_PASSWORD", "Val@2026")
env = env  # noqa: F821 - odoo shell injects this

Users = env["res.users"].sudo()
Applicant = env["hr.applicant"].sudo()
Assessment = env["assessments.be"].sudo()
Generator = env["assessments.be.prompt"].sudo()
Question = env["assessments.be.question"].sudo()
QDim = env["assessments.be.question.dimension"].sudo()

company = env.ref("base.main_company")
G_ADMIN = env.ref("assessments_be_v2.group_assessment_manager")
G_MANAGER = env.ref("assessments_be_v2.group_assessment_manager_restricted")
G_CANDIDATE = env.ref("assessments_be_v2.group_assessment_candidate")


def upsert_user(login, name, groups):
    user = Users.with_context(active_test=False).search(
        [("login", "=", login)], limit=1)
    vals = {
        "name": name,
        "login": login,
        "email": login,
        "company_id": company.id,
        "company_ids": [(6, 0, [company.id])],
        "password": PASSWORD,
        # (6,0) so a re-run resets the rung rather than accumulating groups -
        # the whole point of these accounts is that each holds exactly one.
        "group_ids": [(6, 0, [g.id for g in groups])],
    }
    if user:
        user.write(vals)
    else:
        user = Users.with_context(
            no_reset_password=True, mail_create_nosubscribe=True,
            mail_create_nolog=True, tracking_disable=True,
        ).create(vals)
    return user


admin = upsert_user("cj.admin@val.local", "VAL Admin", [G_ADMIN])
manager = upsert_user("cj.manager@val.local", "VAL Manager", [G_MANAGER])
candidate = upsert_user("cj.candidate@val.local", "VAL Candidate", [G_CANDIDATE])

# A PORTAL account, for the refusal path. Deliberately NOT given any assessment
# group - it cannot hold one, which is the rule being demonstrated.
portal = upsert_user("cj.portal@val.local", "VAL Portal Contact",
                     [env.ref("base.group_portal")])

# ── the pool ──────────────────────────────────────────────────────────────
generator = Generator.search([("name", "=", "VAL Generator")], limit=1)
if not generator:
    generator = Generator.create({"name": "VAL Generator"})

existing = {q.name: q for q in Question.search(
    [("generator_id", "=", generator.id)])}
for i in range(1, 7):
    name = "VAL Q%d" % i
    if name in existing:
        continue
    question = Question.create({
        "name": name,
        "question_type": "mcq",
        "prompt": "VAL question %d - pick the first option." % i,
        "generator_id": generator.id,
        "time_minutes": 2,
    })
    QDim.create({
        "question_id": question.id,
        "name": "Answer",
        "option_line_ids": [
            (0, 0, {"name": opt, "sequence": n * 10, "is_correct": n == 0})
            for n, opt in enumerate(("Correct choice", "Wrong choice"))
        ],
    })

pool = Question.search([("generator_id", "=", generator.id)])


def applicant_for(user, name):
    row = Applicant.search([("email_from", "=", user.login)], limit=1)
    if not row:
        row = Applicant.create({
            "partner_name": name,
            "email_from": user.login,
            "be_candidate_user_id": user.id,
        })
    else:
        row.write({"be_candidate_user_id": user.id})
    return row


cand_applicant = applicant_for(candidate, "VAL Candidate")

# An applicant whose address IS the portal login, bound directly. This is the
# LEGACY shape - `_ensure_candidate_user` refuses to create it now, so it has to
# be written straight onto the field to exist at all.
legacy = Applicant.search([("email_from", "=", portal.login)], limit=1)
if not legacy:
    legacy = Applicant.create({
        "partner_name": "VAL Portal Contact",
        "email_from": portal.login,
    })
legacy.write({"be_candidate_user_id": portal.id})

# ── a DRAFT assessment: the shortlist is editable here ────────────────────
draft = Assessment.search([("name", "=", "VAL Draft - shortlist me")], limit=1)
if not draft:
    draft = Assessment.create({
        "name": "VAL Draft - shortlist me",
        "generator_id": generator.id,
        "duration_minutes": 30,
        "question_limit": 0,
        "evaluator_ids": [(6, 0, [cand_applicant.id])],
    })
draft.write({"state": "draft", "generator_id": generator.id,
             "duration_minutes": 30, "question_limit": 0,
             "evaluator_ids": [(6, 0, [cand_applicant.id])]})

# ── a LAUNCHED assessment: the shortlist is inert here ────────────────────
live = Assessment.search([("name", "=", "VAL Launched - paper is fixed")],
                         limit=1)
if not live:
    live = Assessment.create({
        "name": "VAL Launched - paper is fixed",
        "generator_id": generator.id,
        "duration_minutes": 30,
        # MATCHES the shortlist below. A cap of 3 over a 4-question shortlist
        # is legal but makes the demo unreadable: the list column shows the
        # CAP and the detail shows the SHORTLIST, so the same paper read 3 in
        # one place and 4 in the other and looked like a bug.
        "question_limit": 4,
        "evaluator_ids": [(6, 0, [cand_applicant.id])],
    })
if live.state == "draft":
    # Shortlist 4 of the 6 BEFORE launching, so the launched paper proves the
    # narrowing actually took effect.
    live.write({"question_ids": [(6, 0, pool[:4].ids)], "question_limit": 4})
    live.action_start()

env.cr.commit()

print("")
print("=" * 66)
print("SEEDED etp_validate")
print("=" * 66)
print("password for every login below: %s" % PASSWORD)
for u, role in ((admin, "Admin"), (manager, "Manager (read-only)"),
                (candidate, "Candidate"), (portal, "PORTAL - has no access")):
    print("  %-26s %s" % (u.login, role))
print("")
print("generator      : %s (%d questions)" % (generator.name, len(pool)))
print("draft assessment   : id=%s  %r  state=%s" % (
    draft.id, draft.name, draft.state))
print("launched assessment: id=%s  %r  state=%s  drawn=%d of %d" % (
    live.id, live.name, live.state, len(live.question_ids), len(pool)))
tok = live.assessment_evaluator_ids[:1].access_token or "<none>"
print("candidate exam token: %s" % tok)
print("  legacy /pro_assessment/%s  should REDIRECT to the app" % tok)
print("=" * 66)
