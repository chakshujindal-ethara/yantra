# -*- coding: utf-8 -*-
"""assessments_be_v2 19.0.3.19.0 post-migration: backfill the Candidate group.

WHY THIS EXISTS, AND WHY IT IS THE RISKIEST SCRIPT IN THE ADDON. 19.0.3.19.0
puts a real authorisation check on the candidate API: `/api/v1/me/*` and every
`/api/v1/exam/<token>/*` route now require `group_assessment_candidate`.
Before it, `auth="user"` meant only "not the public user" and authorisation was
the exam token plus an integer identity match - so candidate ability rode on
`base.group_user`, which every employee in the instance holds. That is the hole
being closed: "Assessment v2 Access = No" still let a person sit an exam.

The group is granted going forward at every binding point in
`assessments.be._ensure_candidate_user`. Nobody who is ALREADY a candidate has
it. Without this script, every live candidate is refused at their own exam door
the moment the module is upgraded - mid-sitting, with a 403 and no way round it.
Getting the enumeration too NARROW here is the failure mode that matters; too
wide only means an extra person can open an empty assessment list.

WHY POST-MIGRATE, WHICH THE ONE EARLIER EXAMPLE IN THIS ADDON IS NOT.
`19.0.3.7.0/pre-migrate.py` runs pre precisely because it must read a column
value the new registry can no longer describe. This is the mirror case: it needs
the NEW group's xmlid resolved through `ir_model_data`, and that row is written
when the module's data files load - after pre-migrate, before post-migrate. It
also grants through the ORM, which wants a loaded registry. So post it is.

HOW THE SET IS ENUMERATED - IT MIRRORS THE LIVE GATE, IN ITS ORDER.
`hr.applicant._be_candidate_user` is the authority on who may sit an assessment,
and it has two steps: the explicit bind, then the account whose login IS the
applicant's address. This script proposes with SQL over both, then CONFIRMS each
proposal by calling that very method - the same "propose, then confirm" shape
`_be_applicant_for_user` uses, and for the same reason: a hand-mirrored copy of
the walk is what drifted apart the last three times.

WHY `be_candidate_user_id` ALONE IS NOT ENOUGH. It is provably sparse:

  * `_ensure_candidate_user` has two `return "skipped"` paths that leave it
    unset - an applicant with no `email_from`, and an address already bound to a
    DIFFERENT applicant;
  * the field is `ondelete="set null"`, so deleting a user silently empties it
    while the applicant and their attempts remain;
  * it is `copy=False`, so duplicating an applicant drops it.

Every one of those rows still resolves to a user through the address step, so
every one of them is a candidate the gate will admit and this backfill must
cover.

WHY THE ADDRESS ARM JOINS ON `email_normalized` AND NOT ON `=ilike`. The live
walk searches `login =ilike <address>`, which is a PATTERN: `_` and `%` are
legal in a local-part, so `a_b@corp.com` also matches `axb@corp.com`. That
looseness is deliberate there because `_be_same_person` decides afterwards.
Copying the pattern into a bulk grant would hand the group to wildcard
neighbours, so this joins on the stored, indexed, case-folded
`hr_applicant.email_normalized` - the same column `_be_applicant_for_user`
searches with `=` - and keeps the confirmation step rather than the pattern.

WHY APPLICANT-FIRST AND NOT EVALUATOR-FIRST. An evaluator-keyed walk would miss
a real window: `hr.applicant._be_ensure_applicant_for_user` binds the applicant
BEFORE the roster row is written, so somebody assigned from the directory exists
as a bound candidate with no `assessments_be_evaluator` row yet. Applicant-first
also covers a candidate whose attempts were deleted but whose bind remains.

ARCHIVED ROWS COUNT, on both sides. The gate reads
`Users.with_context(active_test=False)` and resolves an archived applicant's
bind without complaint, so an archived-but-live candidate is admitted by the API
and must be granted here. Raw SQL ignores `active` by nature, which is exactly
the behaviour wanted; the ORM half is explicitly `active_test=False`.

WHY THE GRANT GOES THROUGH THE ORM. `res_users._get_group_ids` is
`@tools.ormcache('self.id')` and `has_group` is `group_id in _get_group_ids()`
(base/models/res_users.py), so a raw `INSERT INTO res_groups_users_rel` leaves
every worker answering the OLD group set until the entry happens to be evicted -
a backfill that appears to have worked and still locks people out.

Either ORM side clears that cache, contrary to what is easy to assume: the user
side because `res.users.write` lists `group_ids` in `_get_invalidation_fields`
and calls `registry.clear_cache()`, the group side because
`call_cache_clearing_methods` -> `clear_cache('stable')` expands to include the
`default` cache (orm/registry.py `_CACHES_BY_KEY`). The USER side is used here
for a different reason: it is the one that runs `_check_disjoint_groups` over
exactly the users being written, which is what makes the per-user retry below
able to isolate a single bad account.

WHAT IT REFUSES TO DO: TOUCH A PORTAL ACCOUNT. THIS IS A POLICY, NOT A
WORKAROUND. This platform is for INTERNAL users; a portal account has no access
to it, is not a candidate, and is never converted into one. Promoting an account
changes what it costs - an internal user occupies a paid Odoo seat where a portal
user does not - and hands it the back office. That is a decision for a person,
with a bill attached, and a migration is the wrong place to make it silently for
an unknown number of accounts.

The mechanics happen to agree, which is why this was previously written up as if
the constraint were the reason: `group_assessment_candidate` implies
`base.group_user`, and `res.users._check_disjoint_groups` forbids a user being
both portal and internal, so granting it to a portal account raises
ValidationError at FLUSH - in a migration, aborting the upgrade and taking every
other grant with it. Both facts point the same way. Only the first is the reason.

So those accounts are IDENTIFIED, LEFT ALONE, AND NAMED IN THE LOG, individually
and with their ids, so the list is directly actionable. They keep their bind and
their attempts; the candidate API refuses them until somebody resolves each one
deliberately - by re-inviting the person on an address that is not already a
portal login, or by converting that account by hand having decided to pay for the
seat. `assessments.be._ensure_candidate_user` enforces the same rule going
forward, and refuses at ASSIGN time rather than leaving anybody to discover it at
their own exam door.

Idempotent and re-runnable: a user who already holds the group (directly or
through Manager/Admin) is skipped, so a second run grants nothing and logs zero.
Every table and column is guarded, so this is a no-op on a fresh install.
"""
import logging

from odoo import SUPERUSER_ID, api

_logger = logging.getLogger(__name__)

VERSION = "19.0.3.19.0"
CANDIDATE_GROUP = "assessments_be_v2.group_assessment_candidate"


def _table_exists(cr, table):
    cr.execute(
        "SELECT 1 FROM information_schema.tables WHERE table_name = %s",
        (table,),
    )
    return bool(cr.fetchone())


def _column_exists(cr, table, column):
    cr.execute(
        "SELECT 1 FROM information_schema.columns "
        "WHERE table_name = %s AND column_name = %s",
        (table, column),
    )
    return bool(cr.fetchone())


def _proposed_applicant_ids(cr):
    """Applicants that the live gate could resolve to a user, as ids.

    SQL only NARROWS - see the module docstring. Nothing is granted off this
    list; `_be_candidate_user` decides. Both arms are deliberately unfiltered on
    `active`.
    """
    arms = ["""
        SELECT a.id
          FROM hr_applicant a
          JOIN res_users u ON u.id = a.be_candidate_user_id
    """]
    if _column_exists(cr, "hr_applicant", "email_normalized"):
        # `lower(login)` as well as `login`: a login stored with capitals is a
        # real legacy shape in this database (see
        # `test_a_provisioned_login_is_always_reachable_by_its_owner`), and
        # `email_normalize` lower-cases an ascii local part - but leaves a
        # non-ascii one alone, which the bare `=` arm catches.
        arms.append("""
            SELECT a.id
              FROM hr_applicant a
              JOIN res_users u
                ON u.login = a.email_normalized
                OR lower(u.login) = a.email_normalized
             WHERE COALESCE(a.email_normalized, '') <> ''
        """)
    else:
        # Degrade to the bind arm rather than skipping the backfill outright:
        # some candidates is strictly better than none, and the gap is named.
        _logger.warning(
            "assessments_be_v2 %s: hr_applicant.email_normalized is missing, so "
            "candidates bound only by ADDRESS could not be enumerated. Re-run "
            "the upgrade once the mail columns exist, or grant %s by hand.",
            VERSION, CANDIDATE_GROUP)
    cr.execute(" UNION ".join(arms))
    rows = cr.fetchall()
    _logger.info(
        "assessments_be_v2 %s: %d applicant row(s) proposed by the enumeration "
        "(%d distinct).", VERSION, cr.rowcount, len({r[0] for r in rows}))
    return sorted({row[0] for row in rows})


def _grant(cr, users, group):
    """Additively grant ``group`` to ``users``. Returns those actually granted.

    One batched write, because it clears the group cache once and validates
    once. The per-user retry is not defensive noise: `_check_disjoint_groups`
    raises for the whole recordset if ANY member of it conflicts, and one
    pathological account must not cost every other candidate their access. The
    savepoint is what makes a failure survivable - `cr.savepoint()` flushes on
    entry and exit, so a deferred `@api.constrains` error is raised inside it
    rather than poisoning the transaction later.
    """
    if not users:
        return users
    command = {"group_ids": [(4, group.id)]}
    try:
        with cr.savepoint():
            users.write(command)
        return users
    except Exception:  # noqa: BLE001 - one bad row must not lose the rest
        _logger.exception(
            "assessments_be_v2 %s: the batched grant of %s to %d user(s) "
            "failed; retrying one at a time.", VERSION, group.name, len(users))
    granted = users.browse()
    for user in users:
        try:
            with cr.savepoint():
                user.write(command)
            granted |= user
        except Exception:  # noqa: BLE001 - report and carry on
            _logger.exception(
                "assessments_be_v2 %s: could not grant %s to user %s (id=%s). "
                "This account will be refused by the candidate API until it is "
                "granted by hand.", VERSION, group.name, user.login, user.id)
    return granted


def migrate(cr, version):
    # Falsy on a fresh install: there are no pre-existing candidates, and
    # `_ensure_candidate_user` grants the group to every new one.
    if not version:
        return

    if not (_table_exists(cr, "hr_applicant") and _table_exists(cr, "res_users")
            and _column_exists(cr, "hr_applicant", "be_candidate_user_id")):
        _logger.warning(
            "assessments_be_v2 %s: hr_applicant.be_candidate_user_id is not "
            "present, so no candidate could be enumerated and NOBODY was "
            "granted %s. Existing candidates will be refused by the API until "
            "this is resolved.", VERSION, CANDIDATE_GROUP)
        return

    env = api.Environment(cr, SUPERUSER_ID, {})
    group = env.ref(CANDIDATE_GROUP, raise_if_not_found=False)
    if not group:
        # Post-migrate runs after the data files load, so this should be
        # unreachable. Failing loudly and returning beats aborting an upgrade.
        _logger.warning(
            "assessments_be_v2 %s: %s does not exist yet, so the candidate "
            "backfill did not run. Re-run the upgrade.",
            VERSION, CANDIDATE_GROUP)
        return

    applicant_ids = _proposed_applicant_ids(cr)
    if not applicant_ids:
        _logger.info(
            "assessments_be_v2 %s: no candidate applicants found; nothing to "
            "grant.", VERSION)
        return

    # CONFIRMED BY THE LIVE GATE ITSELF, not by a mirror of it. Browsed as one
    # recordset so the bind and the address are prefetched in two queries.
    Applicant = env["hr.applicant"].sudo().with_context(active_test=False)
    user_ids = set()
    unresolved = 0
    for applicant in Applicant.browse(applicant_ids).exists():
        confirmed = applicant._be_candidate_user()
        if confirmed:
            user_ids.add(confirmed.id)
        else:
            # Proposed by the address join and refused by `_be_same_person` -
            # a wildcard neighbour, or a display-name address that normalises
            # to somebody else. Correctly NOT a candidate.
            unresolved += 1

    Users = env["res.users"].sudo().with_context(active_test=False)
    internal = env.ref("base.group_user", raise_if_not_found=False)
    # The type groups that COLLIDE with Candidate: `all_implied_ids` is the
    # reflexive closure (Candidate + base.group_user), so what is left is portal
    # and public.
    exclusive = (env["res.groups"]._get_user_type_groups()
                 - group.all_implied_ids)

    already = Users.browse()
    blocked = Users.browse()
    to_grant = Users.browse()
    for user in Users.browse(sorted(user_ids)).exists():
        held = user.all_group_ids
        if group in held:
            already |= user
        elif held & exclusive:
            blocked |= user
        else:
            to_grant |= user

    # A grant that ADDS base.group_user changes what the account costs, so it is
    # counted and reported rather than buried. In practice this is empty: every
    # account provisioned by this module is internal already, and a portal one
    # lands in `blocked` above.
    seat_changes = (to_grant.filtered(lambda u: internal not in u.all_group_ids)
                    if internal else Users.browse())

    granted = _grant(cr, to_grant, group)

    _logger.info(
        "assessments_be_v2 %s: %d candidate account(s) granted %s; %d already "
        "held it (directly or through Manager/Admin); %d applicant(s) proposed "
        "by address were not confirmed as candidates; %d account(s) gained an "
        "internal seat.",
        VERSION, len(granted), CANDIDATE_GROUP, len(already), unresolved,
        len(seat_changes))
    if len(granted) != len(to_grant):
        _logger.error(
            "assessments_be_v2 %s: %d of %d intended grants did not land. Those "
            "candidates CANNOT sit an assessment until they are granted %s.",
            VERSION, len(to_grant) - len(granted), len(to_grant),
            CANDIDATE_GROUP)
    if blocked:
        # NOT CONVERTED, BY POLICY - see the module docstring. This platform is
        # internal-only; a portal account is not a candidate and promoting one
        # would buy a paid seat on somebody's behalf. The list is logged in full,
        # with ids, because it is the operator's work queue: nothing else in the
        # system will tell them which accounts these are.
        _logger.warning(
            "assessments_be_v2 %s: %d candidate account(s) are PORTAL or PUBLIC "
            "users. This platform is for internal users only, so they were left "
            "untouched and NOT granted %s - converting an account is a paid-seat "
            "decision and is never done automatically. They keep their bind and "
            "their attempts; the candidate API refuses them until each is "
            "resolved by hand, either by re-inviting the person on an address "
            "that is not already a portal login, or by deliberately converting "
            "that account to an internal user. The accounts are: %s",
            VERSION, len(blocked), CANDIDATE_GROUP,
            ", ".join("%s (id=%s)" % (u.login, u.id) for u in blocked))
